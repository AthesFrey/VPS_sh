<h1>Cloud Commander Debian 一键安装器</h1>
<p><code>install-cloudcmd.sh</code> 面向 Debian 12/13 的 systemd VPS，固定把 Cloud Commander 安装到 <code>/opt/clcmd</code>，首次默认端口为 <code>5269</code>。程序以 root 运行，因为 Cloud Commander 需要访问用户指定的媒体库；面板认证默认开启。</p>
<h2>使用</h2>
<p>首次安装需要在 SSH 终端运行，并按提示输入媒体库绝对路径、用户名和密码。媒体库不存在时会创建，已有目录不会被递归修改权限。</p>
<pre><code>sudo bash install-cloudcmd.sh
</code></pre>
<p>也可以在启动时指定目录或端口：</p>
<pre><code>sudo bash install-cloudcmd.sh --root &#39;/data/我的媒体库&#39;
sudo bash install-cloudcmd.sh --port 5269
</code></pre>
<p>重新运行脚本会查询 npm <code>latest</code> 并安装升级版本，保留当前凭据和配置。升级时默认保留旧媒体库和端口；只有显式传入 <code>--root</code> 或 <code>--port</code> 才会修改它们。</p>
<p>只读检查：</p>
<pre><code>sudo bash install-cloudcmd.sh --check
</code></pre>
<p>成功后：</p>
<pre><code>http://&lt;VPS-IP&gt;:5269/
</code></pre>
<p>服务管理命令：</p>
<pre><code>sudo systemctl status cloudcmd.service --no-pager
sudo journalctl -u cloudcmd.service -n 100 --no-pager
</code></pre>
<h2>目录和升级安全性</h2>
<ul>
<li><code>/opt/clcmd/releases/release.*</code> 保存候选和已验证版本，<code>current</code> 是当前版本，<code>previous</code> 保留上一个回滚版本。</li>
<li>每个版本带独立 Node.js LTS 运行时和 npm 本地依赖，避免依赖 Debian 默认 Node 版本。Node.js 下载会按官方 <code>SHASUMS256.txt</code> 校验。</li>
<li>配置保存在 <code>/opt/clcmd/current/home/.cloudcmd.json</code>，权限为 <code>0600</code>；systemd 的 <code>HOME</code> 与候选检查环境一致，网页保存的设置会在重启后读取。</li>
<li>下载、npm 安装、HTTP 认证和指定媒体库首页检查都通过后才切换 <code>current</code>。切换或服务健康检查失败会恢复旧版本和旧 systemd 单元。</li>
<li>安装器只接管带有自身标记的 <code>/opt/clcmd</code> 和 <code>cloudcmd.service</code>；发现未知文件、非本脚本服务或额外 systemd drop-in 时会退出，不覆盖现有部署。</li>
<li><code>--root</code> 设置的是 Cloud Commander 的文件根目录，不是操作系统 bind mount；它不会移动或复制媒体文件。</li>
</ul>
<p>脚本默认只提供 HTTP。HTTPS、域名、防火墙和外部访问控制应由已有的反向代理或 VPS 防火墙负责。</p>
<h2>要求和限制</h2>
<ul>
<li>Debian 12/13、amd64 或 arm64、systemd 正常运行。</li>
<li>Cloud Commander 当前 npm 包要求 Node.js <code>&gt;=22</code>；脚本使用 Node.js 官方 LTS，并在每次安装时读取 npm latest。</li>
<li>首次安装必须有可读的 <code>/dev/tty</code>，不能通过管道把密码传给脚本。</li>
<li>root 运行意味着面板的文件操作和内置控制台具有 root 权限；应限制 5269 端口来源或放在 HTTPS 反向代理后。</li>
</ul>
<h2>验证</h2>
<p>开发机可以运行：</p>
<pre><code>bash -n install-cloudcmd.sh
/srv/paseo/tools/shellcheck-v0.11.0/shellcheck -x install-cloudcmd.sh
bash tests/test-install-cloudcmd.sh
</code></pre>
<p>真实 Debian VPS 上安装完成后，<code>--check</code> 会验证服务启用状态、Node 进程来自当前版本、5269（或显式端口）由该服务监听、HTTP 未认证返回 <code>401</code>，并检查媒体库根目录可访问。</p>
