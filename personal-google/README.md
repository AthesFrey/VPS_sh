# Personal Google Browser

这个安装包会在 VPS 上运行一个带网页登录认证的远程 Firefox。浏览器从 VPS 直接访问 Google 官方网站，Nginx Proxy Manager（NPM）负责 HTTPS 和公网代理。Google 账号会话保存在 VPS 的 Firefox 配置目录中。

## 部署

目标 VPS 需要已安装 Docker Engine、Docker Compose v2 和名为 `npm` 且正在运行的 NPM 容器。先在 Cloudflare 将域名的 A 记录指向该 VPS，并确认公网 TCP 80/443 可以到达 NPM。首次申请 Let's Encrypt 证书时，建议 DNS 记录暂时使用 DNS only（灰云）。

首次安装会交互询问 Firefox 登录用户名和密码。用户名留空时使用 `google`；密码需要至少 8 位并输入两次。提示是隐藏密码的。脚本通过 `/dev/tty` 读取输入，因此可以直接使用管道安装：

```sh
curl -fsSL https://raw.githubusercontent.com/AthesFrey/VPS_sh/refs/heads/main/personal-google/install_google_search.sh | sudo bash
```

普通重跑会复用原凭据和 Firefox 配置，并拉取上游 `jlesage/firefox:latest` 镜像后更新或启动服务。需要应用上游新版本时，重新运行安装命令；安装后不会后台自动更新。安装文件保存在 `/opt/personal-google-browser`；凭据写入权限为 `600` 的 `.env`，Firefox 配置和 Google 登录状态保存在 `firefox-config/`。重跑时会保留 `.env` 和 `firefox-config/`。

如果忘记网页登录凭据，可在 VPS 上运行 `sudo cat /opt/personal-google-browser/.env` 查看。不要分享这个文件或 `firefox-config/`。

## Firefox 容器特性

- 使用 [jlesage/docker-firefox](https://github.com/jlesage/docker-firefox) 发布的 `jlesage/firefox:latest` 镜像；该标签会随上游发布移动，运行安装脚本会拉取当时的最新镜像。
- 容器启动后打开 Google，启用网页登录认证和 HTTPS；通过 NPM 代理访问，不向 VPS 宿主机映射端口。
- Firefox 配置、浏览器数据和 Google 登录状态保存在 `/opt/personal-google-browser/firefox-config/`；容器异常退出后会自动重启。
- Web Terminal、Web File Manager 和通知已关闭；主机剪贴板同步与中日韩字体已开启。

### 完全重置

`--force` 会要求输入 `RESET`，然后重新设置用户名和密码，并删除本工具管理的 Firefox 容器、Firefox 配置和旧凭据。它会保留 NPM 容器、NPM 页面配置和 Docker 网络。这个操作会清除 Google 登录状态及浏览器内的数据：

```sh
curl -fsSL https://raw.githubusercontent.com/AthesFrey/VPS_sh/refs/heads/main/personal-google/install_google_search.sh | sudo bash -s -- --force
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

## 输入中文

脚本已开启主机剪贴板自动同步（`WEB_HOST_CLIPBOARD_SYNC=1`）和中日韩字体，无需在 Firefox 容器里安装中文输入法。先在手机或电脑上用设备自带的中文输入法输入并复制文字，再切回远程 Firefox，把光标放进 Google 搜索框并粘贴。

如果剪贴板没有同步，确认当前通过 HTTPS 访问，并在浏览器提示时允许此网站使用剪贴板。部分手机浏览器会限制后台网页或剪贴板权限；这时可把远程 Firefox 页面保持在前台后重新复制，或使用浏览器提供的“粘贴”操作。

`ENABLE_CJK_FONT=1` 负责显示中文字符；中文拼音转换由访问网页的设备输入法完成。

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

## 卸载

先在 NPM 的 Proxy Hosts 页面删除转发到 `google-browser:5800` 的代理主机。卸载脚本不会修改 NPM 页面配置、证书或 DNS。

```sh
curl -fsSL https://raw.githubusercontent.com/AthesFrey/VPS_sh/refs/heads/main/personal-google/uninstall_google_search.sh | sudo bash
```

脚本会停止并删除本工具的 Firefox 容器，以及 `/opt/personal-google-browser` 下的凭据、浏览器配置和 Google 登录状态；删除数据前不会要求确认。若 Firefox 镜像没有被其他容器使用，脚本会自动移除 `jlesage/firefox:latest`。

删除 Docker 网络前，脚本会列出 VPS 上的 Docker 网络和 `personal-google-browser-proxy` 上连接的容器。确认要删除该目标网络时，输入完整名称 `personal-google-browser-proxy`；直接回车或输入其他内容会保留网络。删除网络会断开该网络上的所有容器连接，但不会删除这些容器。
