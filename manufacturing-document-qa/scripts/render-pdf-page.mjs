import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { inflateSync } from 'node:zlib';
import { decodeJbig2ObjectToCanvas, readIndirectObject } from './decode-jbig2-object.mjs';

const args = process.argv.slice(2);
const value = (name, fallback = undefined) => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : fallback;
};

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const skillRoot = path.resolve(scriptDir, '..');
const workspaceRoot = path.resolve(scriptDir, '..', '..');
const localToolsRoot = path.join(skillRoot, 'node_modules');
const legacyToolsRoot = path.join(workspaceRoot, '_qa_work', 'tools', 'node_modules');
const toolsRoot = fs.existsSync(localToolsRoot) ? localToolsRoot : legacyToolsRoot;
const pdfPath = value('--pdf');
const pageNumber = Number(value('--page'));
const outputPath = value('--output');
const scale = Number(value('--scale', '2'));
const rotation = Number(value('--rotation', '0'));
const pdfjsEntry = value('--pdfjs', path.join(toolsRoot, 'pdfjs-dist', 'legacy', 'build', 'pdf.mjs'));

if (!pdfPath || !outputPath || !Number.isInteger(pageNumber)) {
  throw new Error('usage: render-pdf-page.mjs --pdf <path> --page <integer> --output <png> [--scale 2] [--rotation 0|90|-90]');
}
if (!(scale > 0 && scale <= 6)) throw new Error('scale must be greater than 0 and no more than 6');
if (![0, 90, -90].includes(rotation)) throw new Error('rotation must be 0, 90, or -90');
if (!fs.existsSync(pdfPath)) throw new Error(`PDF not found: ${pdfPath}`);
if (!fs.existsSync(pdfjsEntry)) throw new Error(`pdfjs-dist not found: ${pdfjsEntry}`);

const require = createRequire(import.meta.url);
const canvasModule = require(path.join(toolsRoot, '@napi-rs', 'canvas'));
const { createCanvas, DOMMatrix, ImageData, Path2D } = canvasModule;
globalThis.DOMMatrix = DOMMatrix;
globalThis.ImageData = ImageData;
globalThis.Path2D = Path2D;

function escapeRegExp(input) {
  return input.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function extractBalancedDictionary(text, start) {
  if (text.slice(start, start + 2) !== '<<') return null;
  let depth = 0;
  for (let index = start; index < text.length - 1; index += 1) {
    const token = text.slice(index, index + 2);
    if (token === '<<') {
      depth += 1;
      index += 1;
    } else if (token === '>>') {
      depth -= 1;
      index += 1;
      if (depth === 0) return text.slice(start, index + 1);
    }
  }
  return null;
}

function referenceForKey(dictionary, key) {
  const match = new RegExp(`/${escapeRegExp(key)}\\b\\s+(\\d+)\\s+(\\d+)\\s+R`).exec(dictionary);
  if (!match) return null;
  return { objectNumber: Number(match[1]), generation: Number(match[2]) };
}

function dictionaryForKey(dictionary, key, bytes, source) {
  const marker = new RegExp(`/${escapeRegExp(key)}\\b`).exec(dictionary);
  if (!marker) return null;
  let valueStart = marker.index + marker[0].length;
  while (/\s/.test(dictionary[valueStart] ?? '')) valueStart += 1;
  if (dictionary.slice(valueStart, valueStart + 2) === '<<') {
    return extractBalancedDictionary(dictionary, valueStart);
  }

  const reference = /^(\d+)\s+(\d+)\s+R\b/.exec(dictionary.slice(valueStart));
  if (!reference) return null;
  return readIndirectObject(bytes, source, Number(reference[1]), Number(reference[2])).dictionary;
}

function findInheritedResources(pageDictionary, bytes, source) {
  let dictionary = pageDictionary;
  const visited = new Set();
  for (let depth = 0; depth < 32; depth += 1) {
    const resources = dictionaryForKey(dictionary, 'Resources', bytes, source);
    if (resources) return resources;
    const parent = referenceForKey(dictionary, 'Parent');
    if (!parent) return null;
    const key = `${parent.objectNumber}:${parent.generation}`;
    if (visited.has(key)) return null;
    visited.add(key);
    dictionary = readIndirectObject(bytes, source, parent.objectNumber, parent.generation).dictionary;
  }
  return null;
}

function referencesForKey(dictionary, key) {
  const marker = new RegExp(`/${escapeRegExp(key)}\\b`).exec(dictionary);
  if (!marker) return [];
  let valueStart = marker.index + marker[0].length;
  while (/\s/.test(dictionary[valueStart] ?? '')) valueStart += 1;
  let valueText = dictionary.slice(valueStart);
  if (valueText.startsWith('[')) {
    const closing = valueText.indexOf(']');
    if (closing < 0) return [];
    valueText = valueText.slice(1, closing);
  }
  const references = [];
  for (const match of valueText.matchAll(/(\d+)\s+(\d+)\s+R\b/g)) {
    references.push({ objectNumber: Number(match[1]), generation: Number(match[2]) });
    if (!dictionary.slice(valueStart).startsWith('[')) break;
  }
  return references;
}

function decodeContentStream(object) {
  if (!object.stream) return null;
  if (!/\/Filter\b/.test(object.dictionary)) return object.stream.toString('latin1');
  const filter = /\/Filter\s*(?:\/FlateDecode|\[\s*\/FlateDecode\s*\])/.test(object.dictionary);
  if (!filter) return null;
  return inflateSync(object.stream).toString('latin1');
}

function matrixCoversPage(matrix, view) {
  const [a, b, c, d, e, f] = matrix;
  const xValues = [e, a + e, c + e, a + c + e];
  const yValues = [f, b + f, d + f, b + d + f];
  const actual = [Math.min(...xValues), Math.min(...yValues), Math.max(...xValues), Math.max(...yValues)];
  const expected = [Math.min(view[0], view[2]), Math.min(view[1], view[3]), Math.max(view[0], view[2]), Math.max(view[1], view[3])];
  const tolerance = Math.max(expected[2] - expected[0], expected[3] - expected[1]) * 0.001 + 0.05;
  return actual.every((coordinate, index) => Math.abs(coordinate - expected[index]) <= tolerance);
}

function detectFullPageJbig2(page, bytes, source) {
  if (!page.ref || !Number.isInteger(page.ref.num)) return null;
  const pageObject = readIndirectObject(bytes, source, page.ref.num, page.ref.gen ?? 0);
  const resources = findInheritedResources(pageObject.dictionary, bytes, source);
  if (!resources) return null;
  const xObjects = dictionaryForKey(resources, 'XObject', bytes, source);
  if (!xObjects) return null;

  const entries = [...xObjects.matchAll(/\/([^\s/<>{}\[\]()]+)\s+(\d+)\s+(\d+)\s+R\b/g)].map((match) => ({
    name: match[1],
    objectNumber: Number(match[2]),
    generation: Number(match[3]),
  }));
  if (entries.length !== 1) return null;

  const candidate = entries[0];
  const imageObject = readIndirectObject(bytes, source, candidate.objectNumber, candidate.generation);
  if (!/\/Subtype\s*\/Image\b/.test(imageObject.dictionary)) return null;
  if (!/\/Filter\s*(?:\/JBIG2Decode\b|\[\s*\/JBIG2Decode\s*\])/s.test(imageObject.dictionary)) return null;

  const contentReferences = referencesForKey(pageObject.dictionary, 'Contents');
  if (!contentReferences.length) return null;
  const contentParts = [];
  for (const reference of contentReferences) {
    const decoded = decodeContentStream(readIndirectObject(bytes, source, reference.objectNumber, reference.generation));
    if (decoded === null) return null;
    contentParts.push(decoded);
  }
  const content = contentParts.join('\n').replace(/%[^\r\n]*/g, ' ');
  const drawOperators = [...content.matchAll(/\/([^\s/<>{}\[\]()]+)\s+Do\b/g)];
  if (drawOperators.length !== 1 || drawOperators[0][1] !== candidate.name) return null;

  const numberPattern = '[-+]?(?:\\d+(?:\\.\\d*)?|\\.\\d+)(?:[eE][-+]?\\d+)?';
  const drawPattern = new RegExp(
    `(${numberPattern})\\s+(${numberPattern})\\s+(${numberPattern})\\s+(${numberPattern})\\s+(${numberPattern})\\s+(${numberPattern})\\s+cm\\s+/${escapeRegExp(candidate.name)}\\s+Do\\b`,
    'g',
  );
  const matrices = [...content.matchAll(drawPattern)].map((match) => match.slice(1, 7).map(Number));
  if (matrices.length !== 1 || !matrixCoversPage(matrices[0], page.view)) return null;
  return candidate;
}

function resizeJbig2Canvas(canvas, requestedScale) {
  // Direct JBIG2 decoding preserves the source pixels. Treat the CLI's default
  // scale of 2 as 1:1 so default output stays lossless and legacy-compatible.
  const factor = requestedScale / 2;
  if (factor === 1) return canvas;
  const resized = createCanvas(
    Math.max(1, Math.ceil(canvas.width * factor)),
    Math.max(1, Math.ceil(canvas.height * factor)),
  );
  const context = resized.getContext('2d');
  context.imageSmoothingEnabled = false;
  context.drawImage(canvas, 0, 0, resized.width, resized.height);
  return resized;
}

function rotateCanvas(canvas, requestedRotation) {
  if (requestedRotation === 0) return canvas;
  const rotated = createCanvas(canvas.height, canvas.width);
  const context = rotated.getContext('2d');
  if (requestedRotation === 90) {
    context.translate(rotated.width, 0);
    context.rotate(Math.PI / 2);
  } else {
    context.translate(0, rotated.height);
    context.rotate(-Math.PI / 2);
  }
  context.drawImage(canvas, 0, 0);
  return rotated;
}

const pdfjsLib = await import(pathToFileURL(pdfjsEntry).href);
const pdfBytes = fs.readFileSync(pdfPath);
const source = pdfBytes.toString('latin1');
const task = pdfjsLib.getDocument({
  data: new Uint8Array(pdfBytes),
  disableWorker: true,
  verbosity: pdfjsLib.VerbosityLevel?.ERRORS ?? 0,
});
try {
  const document = await task.promise;
  if (pageNumber < 1 || pageNumber > document.numPages) {
    throw new Error(`page ${pageNumber} is outside 1..${document.numPages}`);
  }
  const page = await document.getPage(pageNumber);
  let jbig2 = null;
  try {
    jbig2 = detectFullPageJbig2(page, pdfBytes, source);
  } catch {
    // Raw-object inspection is an optimization for simple image-only pages.
    // Compressed/encrypted object layouts must continue through normal pdfjs.
  }

  let outputCanvas;
  if (jbig2) {
    const decoded = decodeJbig2ObjectToCanvas({
      bytes: pdfBytes,
      source,
      objectNumber: jbig2.objectNumber,
      generation: jbig2.generation,
      toolsRoot,
    });
    outputCanvas = resizeJbig2Canvas(decoded.canvas, scale);
  } else {
    const viewport = page.getViewport({ scale });
    outputCanvas = createCanvas(Math.ceil(viewport.width), Math.ceil(viewport.height));
    const context = outputCanvas.getContext('2d');
    await page.render({ canvasContext: context, viewport }).promise;
  }

  outputCanvas = rotateCanvas(outputCanvas, rotation);
  fs.mkdirSync(path.dirname(path.resolve(outputPath)), { recursive: true });
  fs.writeFileSync(outputPath, outputCanvas.toBuffer('image/png'));
  process.stdout.write(JSON.stringify({
    pdf: path.resolve(pdfPath),
    page: pageNumber,
    page_count: document.numPages,
    output: path.resolve(outputPath),
    scale,
    rotation,
  }));
} finally {
  await task.destroy();
}
