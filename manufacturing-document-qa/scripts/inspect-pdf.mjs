import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";

function fail(message, code = 1) {
  process.stderr.write(`${message}\n`);
  process.exit(code);
}

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    if (key !== "--pdf" && key !== "--pdfjs") {
      fail(`Unknown argument: ${key}`, 2);
    }
    if (index + 1 >= argv.length) {
      fail(`Missing value for ${key}`, 2);
    }
    result[key.slice(2)] = argv[index + 1];
    index += 1;
  }
  return result;
}

const args = parseArgs(process.argv.slice(2));
if (!args.pdf) {
  fail("Usage: node inspect-pdf.mjs --pdf <file.pdf> [--pdfjs <pdf.mjs>]", 2);
}

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const skillRoot = path.resolve(scriptDir, "..");
const localPdfjs = path.join(skillRoot, "node_modules", "pdfjs-dist", "legacy", "build", "pdf.mjs");
const pdfPath = path.resolve(args.pdf);
const pdfjsPath = path.resolve(args.pdfjs ?? localPdfjs);

for (const [label, candidate] of [
  ["PDF", pdfPath],
  ["pdfjs-dist entry", pdfjsPath],
]) {
  let stat;
  try {
    stat = fs.statSync(candidate);
  } catch (error) {
    fail(`${label} does not exist: ${candidate}`);
  }
  if (!stat.isFile()) {
    fail(`${label} is not a file: ${candidate}`);
  }
}

let loadingTask;
try {
  const pdfjs = await import(pathToFileURL(pdfjsPath).href);
  const bytes = fs.readFileSync(pdfPath);
  loadingTask = pdfjs.getDocument({
    data: new Uint8Array(bytes),
    disableWorker: true,
  });
  const document = await loadingTask.promise;
  if (!Number.isSafeInteger(document.numPages) || document.numPages < 1) {
    throw new Error(`Invalid physical page count: ${document.numPages}`);
  }
  process.stdout.write(
    `${JSON.stringify({ page_count: document.numPages, bytes: bytes.length })}\n`,
  );
} catch (error) {
  fail(`Unable to inspect PDF: ${error?.message ?? String(error)}`);
} finally {
  if (loadingTask) {
    try {
      await loadingTask.destroy();
    } catch {
      // The page-count result or original parsing error is more useful.
    }
  }
}
