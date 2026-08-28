# Book Training Set Extraction Skill

面向制造、数控、夹具、模具和 CAD/CAM/CAE 书籍的批量问答训练集生成 Skill。

## 安装与使用

1. 在 GitHub 选择 **Code → Download ZIP** 并解压。
2. 在解压目录运行 `npm install --prefix manufacturing-document-qa` 安装 PDF 解析依赖。
3. 用 Codex 打开解压后的文件夹，把待处理 PDF 放在该文件夹根目录。
4. 告诉 Codex：`使用 $manufacturing-document-qa 处理这本书`。

仓库只保存 Skill、确定性脚本和依赖清单，不提交 `node_modules`、Node 可执行文件、书籍或处理中间产物。`package-lock.json` 固定依赖版本；书籍 PDF、生成的 JSONL、OCR 文本、页面图片和 `_qa_work` 进度不会被 Git 跟踪。

## 环境

- Windows 10/11 x64
- PowerShell 5.1 或更高版本
- Node.js 22.13 或 24 及以上版本
- 扫描书 OCR 需要 Windows 已安装“简体中文”OCR 语言；文本型 PDF 不受此项影响

核心说明见 [`manufacturing-document-qa/SKILL.md`](manufacturing-document-qa/SKILL.md)。
