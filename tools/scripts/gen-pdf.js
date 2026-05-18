#!/usr/bin/env node
/**
 * gen-pdf.js — text/markdown 파일을 한국어 PDF로 변환
 *
 * Usage:
 *   node /opt/scripts/gen-pdf.js <input-path> <output-path> [--title="..."]
 *
 * Examples:
 *   node /opt/scripts/gen-pdf.js /data/workspace/exports/resume.txt /data/workspace/exports/resume.pdf
 *   node /opt/scripts/gen-pdf.js report.md report.pdf --title="WVB 주간 보고서"
 *
 * Behavior:
 *   - 입력은 UTF-8 text (txt / md / 일반 텍스트). markdown 헤딩 (#·##)은 굵게 처리
 *   - 한국어 폰트: Pretendard (Dockerfile에서 /opt/fonts/Pretendard-Regular.otf로 보장)
 *   - 출력: A4, 좌우 50pt 마진, 11pt 본문 / 14pt H2 / 16pt H1
 *   - 입력 파일 인코딩 UTF-8 강제
 *
 * Why pdfkit:
 *   - Pure JS, no Chromium 의존 (markdown-pdf 150MB 회피)
 *   - 5MB · Node 24 호환
 *   - 한국어 폰트 직접 embed 지원
 *
 * Ref: docs.openclaw.ai/reference/rich-output-protocol — MEDIA: 디렉티브로 .pdf 첨부
 */

const PDFDocument = require('pdfkit');
const fs = require('fs');
const path = require('path');

// --- args parsing ---
const args = process.argv.slice(2);
if (args.length < 2) {
  console.error('Usage: gen-pdf.js <input-path> <output-path> [--title="..."]');
  process.exit(1);
}

const inputPath = args[0];
const outputPath = args[1];
const titleArg = args.find((a) => a.startsWith('--title='));
const title = titleArg ? titleArg.slice('--title='.length).replace(/^["']|["']$/g, '') : null;

if (!fs.existsSync(inputPath)) {
  console.error(`Error: input file not found: ${inputPath}`);
  process.exit(2);
}

// --- font path (set in Dockerfile.railway) ---
const FONT_PATH = process.env.OPENCLAW_PDF_FONT || '/opt/fonts/Pretendard-Regular.otf';
const FONT_BOLD_PATH = process.env.OPENCLAW_PDF_FONT_BOLD || '/opt/fonts/Pretendard-Bold.otf';

if (!fs.existsSync(FONT_PATH)) {
  console.error(`Error: Korean font not found at ${FONT_PATH}`);
  console.error('Set OPENCLAW_PDF_FONT env or ensure Dockerfile downloads Pretendard');
  process.exit(3);
}

// --- read input ---
const text = fs.readFileSync(inputPath, 'utf-8');

// --- generate PDF ---
const doc = new PDFDocument({
  size: 'A4',
  margins: { top: 50, bottom: 50, left: 50, right: 50 },
  info: {
    Title: title || path.basename(outputPath, path.extname(outputPath)),
    Author: '김팀장 (drwon-claw)',
    Creator: 'OpenClaw + pdfkit',
    Producer: 'WVB',
  },
});

// ensure output directory exists
fs.mkdirSync(path.dirname(outputPath), { recursive: true });

const stream = fs.createWriteStream(outputPath);
doc.pipe(stream);

// register Korean fonts
doc.registerFont('Korean', FONT_PATH);
if (fs.existsSync(FONT_BOLD_PATH)) {
  doc.registerFont('KoreanBold', FONT_BOLD_PATH);
}

// optional title page header
if (title) {
  doc.font(fs.existsSync(FONT_BOLD_PATH) ? 'KoreanBold' : 'Korean')
    .fontSize(18)
    .text(title, { align: 'center' });
  doc.moveDown(1.5);
}

// render body with minimal markdown awareness (#·##·**bold**)
doc.font('Korean').fontSize(11);

const lines = text.split('\n');
for (const rawLine of lines) {
  const line = rawLine.replace(/\r$/, '');

  // H1: # heading
  if (/^#\s+/.test(line)) {
    doc.moveDown(0.5);
    doc.font(fs.existsSync(FONT_BOLD_PATH) ? 'KoreanBold' : 'Korean').fontSize(16);
    doc.text(line.replace(/^#\s+/, ''));
    doc.font('Korean').fontSize(11);
    doc.moveDown(0.5);
    continue;
  }
  // H2: ## heading
  if (/^##\s+/.test(line)) {
    doc.moveDown(0.3);
    doc.font(fs.existsSync(FONT_BOLD_PATH) ? 'KoreanBold' : 'Korean').fontSize(14);
    doc.text(line.replace(/^##\s+/, ''));
    doc.font('Korean').fontSize(11);
    doc.moveDown(0.3);
    continue;
  }
  // H3: ### heading
  if (/^###\s+/.test(line)) {
    doc.moveDown(0.2);
    doc.font(fs.existsSync(FONT_BOLD_PATH) ? 'KoreanBold' : 'Korean').fontSize(12);
    doc.text(line.replace(/^###\s+/, ''));
    doc.font('Korean').fontSize(11);
    doc.moveDown(0.2);
    continue;
  }
  // horizontal rule
  if (/^-{3,}\s*$/.test(line) || /^={3,}\s*$/.test(line)) {
    doc.moveDown(0.3);
    const y = doc.y;
    doc.moveTo(50, y).lineTo(545, y).strokeColor('#888').lineWidth(0.5).stroke();
    doc.moveDown(0.3);
    continue;
  }
  // empty line
  if (line.trim() === '') {
    doc.moveDown(0.5);
    continue;
  }
  // body — write as-is (no inline markdown styling — keep simple)
  doc.text(line, { width: 495, align: 'left' });
}

doc.end();

stream.on('finish', () => {
  const stats = fs.statSync(outputPath);
  console.log(`PDF generated: ${outputPath} (${stats.size} bytes)`);
});

stream.on('error', (err) => {
  console.error(`Error writing PDF: ${err.message}`);
  process.exit(4);
});
