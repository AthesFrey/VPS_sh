# Personal Google Browser

这个安装包会在 VPS 上运行一个带网页登录认证的远程 Firefox。浏览器从 VPS 直接访问 Google 官方网站，Nginx Proxy Manager（NPM）负责 HTTPS 和公网代理。Google 账号会话保存在 VPS 的 Firefox 配置目录中。

## 部署

目标 VPS 需要已安装 Docker Engine、Docker Compose v2 和名为 `npm` 且正在运行的 NPM 容器。先在 Cloudflare 将域名的 A 记录指向该 VPS，并确认公网 TCP 80/443 可以到达 NPM。首次申请 Let's Encrypt 证书时，建议 DNS 记录暂时使用 DNS only（灰云）。

首次安装会交互询问 Firefox 登录用户名和密码。用户名留空时使用 `google`；密码需要至少 8 位并输入两次。提示是隐藏密码的。脚本通过 `/dev/tty` 读取输入，因此可以直接使用管道安装：

```sh
curl -fsSL https://raw.githubusercontent.com/AthesFrey/Paseo-Codex-AI/main/personal-google-browser/install_google_search.sh | sudo bash
```

普通重跑会复用原凭据和 Firefox 配置，拉取脚本指定的 Firefox 镜像并更新或启动服务。安装文件保存在 `/opt/personal-google-browser`；凭据写入权限为 `600` 的 `.env`，Firefox 配置和 Google 登录状态保存在 `firefox-config/`。

如果忘记网页登录凭据，可在 VPS 上运行 `sudo cat /opt/personal-google-browser/.env` 查看。不要分享这个文件或 `firefox-config/`。

### 完全重置

`--force` 会要求输入 `RESET`，然后重新设置用户名和密码，并删除本工具管理的 Firefox 容器、Firefox 配置和旧凭据。它会保留 NPM 容器、NPM 页面配置和 Docker 网络。这个操作会清除 Google 登录状态及浏览器内的数据：

```sh
curl -fsSL https://raw.githubusercontent.com/AthesFrey/Paseo-Codex-AI/main/personal-google-browser/install_google_search.sh | sudo bash -s -- --force
```

## NPM 页面设置

脚本会创建或复用 `personal-google-browser-proxy` Docker bridge 网络，把运行中的 `npm` 容器接入该网络，并启动 Firefox。它会先在 NPM 容器中运行 `nginx -t`；检查成功后才执行平滑 reload。它不会重启 NPM，也不会修改 DNS、证书或 Proxy Host。

在 NPM 的 Proxy Hosts 页面手动新增代理主机：

- **Domain Names**：你自己的域名，例如 `enterprise.kdns.fr`
- **Scheme**：`https`
- **Forward Hostname / IP**：`google-browser`
- **Forward Port**：`5800`
- **Websockets Support**：启用

在 SSL 页面申请 Let's Encrypt 证书，签发成功后启用 **Force SSL**。确认 HTTPS 可用后，可按需将 Cloudflare 改为 Proxied（橙云），并将 SSL/TLS 模式设为 **Full (strict)**。

之后访问你的域名，先使用脚本设置的 Firefox 网页用户名和密码登录，再在远程 Firefox 中登录 Google。Google AI Mode 是否可用仍取决于 Google 账号资格、地区和 VPS 出口位置。

## 数据和维护

Firefox 容器不向 VPS 宿主机映射端口，仅通过 NPM 所在 Docker 网络提供服务。Web Terminal 和 Web File Manager 均已关闭。Firefox 数据持久化在 `/opt/personal-google-browser/firefox-config/`。

查看日志：

```sh
sudo docker compose \
  --project-name personal-google-browser \
  --project-directory /opt/personal-google-browser \
  --env-file /opt/personal-google-browser/.env \
  -f /opt/personal-google-browser/compose.yaml logs -f firefox
```

备份或迁移前，先停止服务并备份 `.env` 与 `firefox-config/`。运行 `--force` 会删除这些浏览器数据；普通重跑不会。
