# ACU 产品落地页部署

页面源码位于 `website/`，使用原生 HTML / CSS / JavaScript，无 npm 依赖或构建步骤。网站部署与 macOS 应用的版本标签、Release 和 Homebrew Cask 更新独立。

## 本地预览

在仓库根目录运行：

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory website
```

打开 <http://127.0.0.1:4173>。网页演示不会开启电脑保护；命令复制需要 localhost 或 HTTPS 安全上下文。

## 部署方案

```text
访客 → https://acu.rectcircle.cn
     → Cloudflare 橙云代理（边缘 HTTPS）
     → Netlify（自定义域名 HTTPS 源站）
     → website/ 静态页面

DNS：CNAME acu → <实际站点名称>.netlify.app
```

DNS 继续由 Cloudflare 管理，只配置 `acu` 子域名，无需迁移 `rectcircle.cn` 的名称服务器。Netlify 必须绑定 `acu.rectcircle.cn`，才能按这个 Host 提供页面和有效源站证书。此方案不使用 Cloudflare Worker、Wrangler 或回源环境变量。

## 1. 配置 Netlify

用户决定上线后，在 Netlify 导入本仓库，选择网站生产分支，使用根目录的 `netlify.toml`：

| 项目 | 设置 |
| --- | --- |
| Base directory | 仓库根目录（留空） |
| Build command | 留空 |
| Publish directory | `website` |
| 配置文件 | 根目录 `netlify.toml` |

取得实际生产站点地址 `https://<实际站点名称>.netlify.app`。在 **Domain management → Production domains** 添加 `acu.rectcircle.cn`，将其设为主域名；不选择 Netlify DNS。若面板要求验证域名所有权，按其给出的记录完成验证。

`netlify.toml` 提供响应安全头与缓存再验证；未知路径由 `website/404.html` 返回 404，没有 SPA 通配回写。

## 2. 配置 Cloudflare CNAME

在 Cloudflare 的 `rectcircle.cn` 区域中添加或更新这一条记录：

| 项目 | 值 |
| --- | --- |
| Type | `CNAME` |
| Name | `acu` |
| Target | `<实际站点名称>.netlify.app` |
| TTL | Auto |
| Proxy status（初始） | DNS only（灰云） |

Target 使用 Netlify 分配的实际生产主机名，不含 `https://`、路径或末尾斜线，不使用 Deploy Preview 地址。若 `acu` 已有同名 A / AAAA / CNAME 记录，先确认用途，再替换为目标 CNAME；不要保留冲突记录。

先保持灰云，让 Netlify 完成 DNS 验证，并在 **Domain management → HTTPS** 为 `acu.rectcircle.cn` 签发证书。确认源站证书有效后，将 CNAME 切换为 **Proxied（橙云）**。

Cloudflare 的 SSL/TLS 加密模式使用 **Full (strict)**；如区域内其他站点使用不同模式，可通过该主机名的配置规则单独设置。不要使用 Flexible。访客到 Cloudflare 使用边缘证书，Cloudflare 到 Netlify 使用匹配 `acu.rectcircle.cn` 的有效源站证书。

若启用 HTTP 到 HTTPS 跳转，使用 Cloudflare 的 Always Use HTTPS 或该主机名的等效重定向规则。

## 3. 维护与发布

- 后续网站修改沿用 Netlify 的 Git 部署流程，不需要推送应用版本标签，也不触发应用 Release 或更新 Cask。
- 保持 Netlify 的自定义域名绑定与证书有效。若代理阻碍域名验证或证书续期，暂时切回灰云，按 Netlify 面板指引处理后再恢复橙云。
- 上线后地址应保持 `acu.rectcircle.cn`，静态资源和中英切换均从该域名加载；页面已使用此域名的 canonical、分享链接与 sitemap。
- 本次只准备本地文件；提交、推送、Netlify 发布及 Cloudflare DNS 变更均未执行。

## 官方参考

- [Netlify 文件配置](https://docs.netlify.com/build/configure-builds/file-based-configuration/)
- [Netlify 外部 DNS 的 CNAME 接入](https://docs.netlify.com/manage/domains/configure-domains/configure-external-dns/)
- [Netlify HTTPS 与证书](https://docs.netlify.com/manage/domains/secure-domains-with-https/https-ssl/)
- [Cloudflare Full (strict) 源站证书要求](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/full-strict/)

## 夸克下载入口

中文安装区左侧介绍栏、兼容性说明与捐赠入口之间显示紧凑的国内下载说明，英文页面隐藏该说明。
配置位于 `website/mirror-config.js`：`url` 填 ACU 永久分享的完整 HTTPS 链接，
`code` 填公开提取码；只有 `https://pan.quark.cn/s/<分享ID>` 链接会被启用。
空链接或非法链接显示“夸克网盘准备中，暂请从 GitHub 下载”，不生成占位下载链接。

通过分享链接确认四个文件可下载后，再填入配置并按现有 Netlify 流程部署。
这里是公开静态配置，不能存放登录凭据。GitHub 的 `QUARK_SHARE_URL`、`QUARK_SHARE_CODE`
只用于 Release Notes，不会自动注入此静态网站；更换分享时需同时维护两处。

当前 ACU 永久分享已填入配置及 HTML 无脚本回退链接。更换分享时两处一并更新。
