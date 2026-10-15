# 发布与夸克镜像维护

GitHub Release 是产物来源。tag 仅创建草稿；用户验收完成后仍须明确授权发布。
只有获得该授权后，才执行下文发布命令。代码开发、CI 成功或验收通过均不是发布授权。

## 首次配置

维护者需要 Python 3.11+、Node（CI 使用 22.14.0）和已登录的 GitHub CLI，以及仓库 Secret/变量写权限。

安装固定版本 CLI 并登录：

```sh
python3 scripts/quark-release.py install-cli
CODEX_CI=1 node "$HOME/.local/share/quark-cli/1.0.24/quark-drive.cjs" login
CODEX_CI=1 node "$HOME/.local/share/quark-cli/1.0.24/quark-drive.cjs" get-user-info
```

安装目录已存在且 `--version` 为 `1.0.24-29460f9` 时跳过安装。浏览器授权后，以 `get-user-info` 成功确认登录。
`CODEX_CI=1` 选择与 runner 一致的 Codex 授权通道，不要求安装 Skill。

**发布 token 获取：** 登录凭据保存在 `~/.local/share/quark-cli/codex/config.json`。
`QUARK_AUTH` 不是单个 token，也不是网页临时授权码，而是包含当前账号 access/refresh token 等必要字段的最小 JSON。
下文 `dispatch` 命令会先验证登录，再从该文件提取凭据，通过标准输入写入仓库 `QUARK_AUTH` Secret；无需手动复制或打印 token。
授权失效时重新执行 `login`。自定义 CLI 位置时，用 `--cli`、`--auth-config` 指定配套路径。

更多 CLI 操作参考[夸克官方 Skill 仓库](https://github.com/quark-clouddrive/quarkclouddrive_offical)。
本项目发布使用脚本校验的固定 CLI 版本，不随 Skill 自动升级。

经用户授权配置网盘后，建立如下目录，只分享 `acu`，不要分享 `releases` 或暂存目录：

```text
/releases/
  acu/                 # 长期分享，版本目录 vX.Y.Z 自动加入
  acu-staging/         # 不分享，由镜像脚本按需创建
```

在 ACU 仓库 Settings → Secrets and variables → Actions 中配置 Repository variables：

| 变量 | 值 |
| --- | --- |
| `QUARK_RELEASES_FID` | 未分享的 `/releases` 目录 ID |
| `QUARK_ACU_FID` | `/releases/acu` 目录 ID；必须属于同一账号 |
| `QUARK_SHARE_URL` | 可选，ACU 长期分享链接，用于新草稿 Release Notes |
| `QUARK_SHARE_CODE` | 可选，公开下载提取码 |

不得复用 FnCPN 的公开目录 ID。切换账号或重建目录时同时更新 FID。
首次启用还需将本地授权同步为本仓库的 `QUARK_AUTH` Secret；下文 `dispatch` 会自动完成。
现有公开版本可先使用 mirror 模式初始化授权并验证链路，不需要发布新版本。
分享链接验证可用后，将真实入口补充到中文 README，并填写 `website/mirror-config.js` 的 `url` 和 `code`。官网入口已实现，未配置时显示准备中；部署步骤见 `website-deployment.md`。

## 每次发布

1. 整理 CHANGELOG 对应版本，运行测试，提交并推送代码，再推送 `vX.Y.Z` 标签。
2. 等待 Release 草稿构建完成，确认 `.tar.gz`、`.dmg` 及各自 `.sha256` 共四个文件；名称为
   `ACU-<版本>-macos-universal.<后缀>`。将草稿交给用户验证并停止。
3. 用户明确授权发布后，运行以下命令（替换示例版本）：

```sh
python3 scripts/quark-release.py dispatch v0.1.8
```

该命令先检查本地授权，仅通过标准输入更新仓库 `QUARK_AUTH` Secret，再触发 main 上的 Release。
不会将凭据放入 workflow input、命令参数或产物。不要同时从多个会话刷新同一账号的 Secret。
也可在凭据已同步时手动 Actions → Release，填写 `version`，但同样必须先获得明确发布授权。
发布任务严格检查四文件清单、校验文件名及安装包 SHA-256、GitHub asset digest，公开原草稿，绝不重新构建。
公开成功后独立执行 Homebrew 和夸克任务；某个失败不撤销已经完成的分发。

4. 用 `gh run list --workflow release.yml` 找到运行，再 `gh run watch <运行ID> --exit-status`。
   检查 publish、update-cask、mirror-quark 三部分，不能仅以 GitHub 已公开判断全部完成。
   夸克日志需有四项文件校验及最终 `Verified mirror:`，并通过分享链接确认版本目录可见。

## 镜像与恢复

镜像只接受已公开的正式版本。下载全部四资产并校验后，上传到未分享的
`/releases/acu-staging/vX.Y.Z/`，从夸克回读每个文件并核对 SHA-256，全部通过后移动到 `acu`。
任务串行执行所有 ACU 版本，runner 使用临时授权目录，结束后清理；不回写刷新后的凭据。
CLI 能刷新令牌，但不承诺长期无人值守；本地授权失效需人工重新登录。

部分上传失败会保留暂存目录，重试先核对已有内容，仅补传缺失文件。
同名内容不同、重复名、额外文件均报错，不自动覆盖或删除远端内容。
已公开的网盘版本只能完整校验，不允许原地补写。目录冲突应人工排查。

已公开版本镜像失败时，修复本地登录或网络后运行：

```sh
python3 scripts/quark-release.py dispatch v0.1.8 --mode mirror
```

也可在凭据有效时手动运行 Quark release mirror 工作流，填写 tag。
Release 使用 GITHUB_TOKEN 公开不会触发另一工作流，因此它显式调用可复用镜像任务；
工作流同时支持 GitHub `release.published` 事件，重复调用会只读核验已完成的版本。

Homebrew 单独失败时，手动执行 Update Homebrew Cask 工作流，填写已公开的 tag。
该任务重新核验四资产，再更新 Cask；不会公开草稿或重新构建。旧版本不会降级 Cask。
不要重新执行 Release 发布入口修复已公开版本。

## 验证范围

本地无网络回归覆盖清单、篡改、凭据隔离、部分上传恢复、冲突拒绝与公开目录不可变。
真正启用时仍须验证本地授权导出、Ubuntu runner 恢复、四文件上传与回读、长期分享可见及重复执行。
在这些操作完成前，不宣称网盘已可下载。令牌自然到期与长期维护另行观察。

## v0.1.7 手动镜像验证（2026-10-15）

已从 GitHub 最新公开正式版 v0.1.7 下载四个原始资产，验证安装包校验和及全部 GitHub asset digest；
手动上传至未分享的暂存目录，四文件逐个回读 SHA-256 一致后移动至 `/releases/acu/v0.1.7/`。
永久分享为 https://pan.quark.cn/s/06f55e51fddb?pwd=rv8F，提取码 `rv8F`；已从分享入口确认版本目录及完整四文件清单。
官网中文安装区入口位于左侧介绍栏，README 使用同一链接。
本次发现移动后列表短暂延迟，脚本已增加有限次数只读重试，避免重复移动或覆盖。
本地验证不等于 Ubuntu Actions 链路已验证；尚未运行自动镜像，发布时仍需同步 `QUARK_AUTH`。
