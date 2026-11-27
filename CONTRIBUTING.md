# 贡献指南

本项目只维护两样东西：一个面向 Termux 的安装脚本 `install.sh`，以及它的文档。
改动可以很小，但必须自包含、可验证、能追溯。本文件说明如何做到这一点。

## 开发环境

你只需要一台能跑 Termux 的 Android 设备，以及一个带 shellcheck 和 Python 3 的环境
用来在提交前跑本地校验。CI 会在每次 push 和 pull request 上重复这些校验。

```bash
pkg install -y git shellcheck python
```

## 提交前验证

CI 会跑下面三项，任何一项失败都不会被合并。提交前请本地先跑一遍：

```bash
bash -n install.sh                      # 1. Bash 语法
shellcheck -S warning install.sh        # 2. 静态分析（warning 及以上视为错误）
python3 .github/check-install.py        # 3. 安装脚本结构契约
```

第三项检查的是本项目特有的契约，改 `install.sh` 时必须遵守：

- **步骤编号**：每个步骤用 `log N/M ...` 打印，N 从 1 连续递增，所有步骤的 M 相同且等于总数。
- **幂等标记**：每个对已安装包的补丁都要带一个可被 `grep -q "marker" "$file"` 检查的标记，
  重复运行安装脚本时据此跳过已打的补丁。
- **内嵌 Python**：以 `<<'PY' ... PY` 嵌入的 Python 代码必须能通过语法编译。
- **README 同步**：README 里编号步骤的条数必须与 `install.sh` 的步骤数一致；
  改了步骤就要同步更新 README（本项目 README 有英文、中文、俄语三个版本，需一起改）。

## 提交信息规范

提交信息采用 [Conventional Commits](https://www.conventionalcommits.org/) 格式，
并遵循 Linux 内核的提交信息习惯：

```
<type>(<scope>): <简短主题，祈使语气，不超过 50 字符>

<正文：解释为什么这么改，而不是改了什么。每行不超过 72 字符。>
必要时可以有多段。

Signed-off-by: 你的名字 <你的邮箱>
```

规则：

- `type` 取 `feat` / `fix` / `docs` / `chore` / `refactor` / `test` / `ci` 之一。
- 主题行用祈使语气（"add"、"fix"、"remove"），首字母小写，结尾不加句号。
- 正文说明动机和背景；"改了什么"交给 diff 本身说明。
- **每个提交只做一件事**。一个提交里混进多个不相关的改动会被要求拆分。
- 一次 pull request 里的多个提交，主题行必须各不相同、各自准确描述本提交的内容。
  不要给所有提交写同一段信息。

### 开发者原创声明（DCO）

本项目要求所有贡献遵守 [DCO 1.1](https://developercertificate.org/)。
你只需要在提交信息末尾加一行署名，即表示你有权以所声明的许可证提交该贡献：

```
Signed-off-by: 你的真实姓名 <你的邮箱>
```

使用 `git commit -s` 可以自动添加这一行。署名必须使用真实姓名和有效邮箱，
且需与 pull request 的提交作者一致。缺少署名的贡献不会被合并。

## Pull Request 流程

1. Fork 本仓库，在你的 fork 上建分支，不要在 `main` 上直接改。
2. 按上面的规范拆分提交，每个提交都带上 `Signed-off-by`。
3. 推送分支后发起 pull request。PR 描述请写清楚：
   - **背景**：为什么要改，解决了什么问题；
   - **改动**：改了哪些文件、大致思路；
   - **测试**：跑了哪些命令、结果如何，以及在什么设备 / 系统版本上验证过（如适用）；
   - **影响面**：是否会影响已有用户、是否需要重新运行安装脚本。
4. 确认 CI 三项校验全绿后再请求审查。
5. 审查中要求的修改，请新增提交或 squash 到相关提交，保持历史清晰；
   不要 force push 覆盖已经有人审查过的提交，除非审查者明确要求。

## 二进制与生成物

`docs/logo.png`、`docs/banner.svg` 这类资源与脚本逻辑无关。
如果确实要替换，请单独用一个 `chore:` 提交，不要和 `install.sh` 的修复混在一起。
注意 `docs/banner.svg` 的星数由 `.github/workflows/sync-stars.yml` 自动同步，
手工改动会被下次同步覆盖。
