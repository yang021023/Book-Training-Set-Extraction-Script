import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const scriptPath = fileURLToPath(import.meta.url);
const scriptDir = path.dirname(scriptPath);
const skillRoot = path.resolve(scriptDir, '..');
const workspaceRoot = path.resolve(scriptDir, '..', '..');
const localToolsRoot = path.join(skillRoot, 'node_modules');
const legacyToolsRoot = path.join(workspaceRoot, '_qa_work', 'tools', 'node_modules');
const defaultToolsRoot = fs.existsSync(localToolsRoot) ? localToolsRoot : legacyToolsRoot;
const jbig2Header = Buffer.from([0x97, 0x4a, 0x42, 0x32, 0x0d, 0x0a, 0x1a, 0x0a, 0x03]);

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

export function readIndirectObject(bytes, source, objectNumber, generation = 0) {
  if (!Number.isInteger(objectNumber) || objectNumber < 1 || !Number.isInteger(generation) || generation < 0) {
    throw new Error(`invalid PDF object reference ${objectNumber} ${generation} R`);
  }

  const pattern = new RegExp(
    `(?:^|[\\r\\n])[\\t ]*${escapeRegExp(String(objectNumber))}[\\t ]+${escapeRegExp(String(generation))}[\\t ]+obj\\b`,
  );
  const match = pattern.exec(source);
  if (!match) throw new Error(`PDF object ${objectNumber} ${generation} not found as a direct object`);

  const bodyStart = match.index + match[0].length;
  const firstEndObject = source.indexOf('endobj', bodyStart);
  if (firstEndObject < 0) throw new Error(`PDF object ${objectNumber} ${generation} has no endobj marker`);

  const streamMarker = source.indexOf('stream', bodyStart);
  if (streamMarker < 0 || streamMarker > firstEndObject) {
    return {
      objectNumber,
      generation,
      dictionary: source.slice(bodyStart, firstEndObject),
      stream: null,
    };
  }

  let streamStart = streamMarker + 'stream'.length;
  // Match the legacy decoder exactly: tolerate non-canonical whitespace before
  // the first JBIG2 byte, as found in the source books in this workspace.
  while (streamStart < bytes.length && [9, 10, 13, 32].includes(bytes[streamStart])) streamStart += 1;
  let streamEnd = source.indexOf('endstream', streamStart);
  if (streamEnd < 0) throw new Error(`PDF object ${objectNumber} ${generation} has no endstream marker`);
  while (streamEnd > streamStart && [9, 10, 13, 32].includes(bytes[streamEnd - 1])) streamEnd -= 1;

  return {
    objectNumber,
    generation,
    dictionary: source.slice(bodyStart, streamMarker),
    stream: bytes.subarray(streamStart, streamEnd),
  };
}

export function decodeJbig2ObjectToCanvas({
  bytes,
  source = bytes.toString('latin1'),
  objectNumber,
  generation = 0,
  toolsRoot = defaultToolsRoot,
}) {
  const object = readIndirectObject(bytes, source, objectNumber, generation);
  if (!object.stream) throw new Error(`PDF object ${objectNumber} ${generation} has no stream`);
  if (!/\/Filter\s*(?:\/JBIG2Decode\b|\[\s*\/JBIG2Decode\s*\])/s.test(object.dictionary)) {
    throw new Error(`PDF object ${objectNumber} ${generation} is not a JBIG2 image stream`);
  }

  const require = createRequire(import.meta.url);
  const { createCanvas } = require(path.join(toolsRoot, '@napi-rs', 'canvas'));
  globalThis.window = globalThis;
  require(path.join(toolsRoot, 'jb2'));
  if (typeof globalThis.Jbig2Image !== 'function') throw new Error('jb2 did not expose Jbig2Image');

  const decoder = new globalThis.Jbig2Image();
  const pixels = decoder.parse(new Uint8Array(Buffer.concat([jbig2Header, object.stream])));
  const canvas = createCanvas(decoder.width, decoder.height);
  const context = canvas.getContext('2d');
  const image = context.createImageData(decoder.width, decoder.height);
  for (let sourceIndex = 0, targetIndex = 0; sourceIndex < pixels.length; sourceIndex += 1, targetIndex += 4) {
    const pixel = pixels[sourceIndex];
    image.data[targetIndex] = pixel;
    image.data[targetIndex + 1] = pixel;
    image.data[targetIndex + 2] = pixel;
    image.data[targetIndex + 3] = 255;
  }
  context.putImageData(image, 0, 0);
  return { canvas, width: decoder.width, height: decoder.height };
}

function argumentValue(args, name) {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : undefined;
}

function main() {
  const args = process.argv.slice(2);
  const pdfPath = argumentValue(args, '--pdf');
  const objectNumber = Number(argumentValue(args, '--object'));
  const outputPath = argumentValue(args, '--output');
  if (!pdfPath || !outputPath || !Number.isInteger(objectNumber) || objectNumber < 1) {
    throw new Error('usage: decode-jbig2-object.mjs --pdf <path> --object <positive integer> --output <png>');
  }
  if (!fs.existsSync(pdfPath)) throw new Error(`PDF not found: ${pdfPath}`);

  const bytes = fs.readFileSync(pdfPath);
  const decoded = decodeJbig2ObjectToCanvas({ bytes, objectNumber });
  fs.mkdirSync(path.dirname(path.resolve(outputPath)), { recursive: true });
  fs.writeFileSync(outputPath, decoded.canvas.toBuffer('image/png'));
  process.stdout.write(JSON.stringify({
    pdf: path.resolve(pdfPath),
    object: objectNumber,
    width: decoded.width,
    height: decoded.height,
    output: path.resolve(outputPath),
  }));
}

if (process.argv[1] && path.resolve(process.argv[1]) === scriptPath) main();
