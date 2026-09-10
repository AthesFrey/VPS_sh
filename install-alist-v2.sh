#!/usr/bin/env bash
# Alist 安装工具 v2.0.0：/opt/alist，HTTP 5268，本地存储 /srv/proj。
set -euo pipefail
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    printf '%s\n' '用法：以 root 执行 bash install-alist.sh' \
        '固定安装到 /opt/alist，使用 5268 端口，将 /srv/proj 挂载到 Alist 首页。' \
        '交互设置管理员密码，并启用 systemd 开机自启。需要 Linux、Python 3.8+ 和 systemd。' \
        '仅支持全新安装；不会覆盖 /opt/alist 或自动迁移旧安装。'
    exit 0
fi
if (( $# != 0 )); then
    printf '%s\n' '不接受路径参数；安装目录固定为 /opt/alist。' >&2
    exit 1
fi
command -v python3 >/dev/null || { echo '请先安装 python3 和 ca-certificates。' >&2; exit 1; }
exec python3 - <<'PY_INSTALLER'
import fcntl
import getpass
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
import uuid


class InstallError(Exception):
    pass


class Installer:
    PORT = 5268
    SERVICE = 'alist.service'
    RELEASE = 'https://api.github.com/repos/AlistGo/alist/releases/latest'

    def __init__(self, root=Path('/')):
        # root 只供隔离测试使用；命令行不提供修改固定路径的选项。
        self.root = Path(root)
        self.target = self.root / 'opt/alist'
        self.media = self.root / 'srv/proj'
        self.unit = self.root / 'etc/systemd/system/alist.service'
        self.proc = None
        self.installed = False
        self.unit_changed = False
        self.service_attempted = False
        self.previous_unit = None
        self.previous_enabled = False
        self.http = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def run_command(self, args, check=True, **kwargs):
        try:
            result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    text=True, timeout=120, **kwargs)
        except subprocess.TimeoutExpired:
            raise InstallError(f'{Path(args[0]).name} 执行超时。') from None
        # 不输出完整命令或原始日志，其中可能包含密码、令牌。
        if check and result.returncode:
            raise InstallError(f'{Path(args[0]).name} 执行失败，退出码 {result.returncode}。')
        return result

    def systemctl(self, *args, check=True):
        return self.run_command(['systemctl', *args], check=check)

    def preflight(self):
        if sys.version_info < (3, 8):
            raise InstallError('需要 Python 3.8 或更新版本。')
        if platform.system() != 'Linux' or os.geteuid() != 0:
            raise InstallError('请在 Linux 服务器上以 root 身份运行此脚本。')
        if not shutil.which('systemctl') or not (self.root / 'run/systemd/system').is_dir():
            raise InstallError('需要正在运行的 systemd；不适用于 Docker 容器或 OpenWrt。')
        if self.target.exists() or self.target.is_symlink():
            raise InstallError(f'{self.target} 已存在。本脚本仅用于全新安装，请先备份并移走原目录。')
        if self.media.exists() and not self.media.is_dir():
            raise InstallError(f'{self.media} 已存在，但不是目录。')
        if self.unit.is_symlink():
            raise InstallError(f'{self.unit} 是符号链接，请先处理原服务配置。')
        state = self.systemctl('show', self.SERVICE, '--property=LoadState,ActiveState,DropInPaths')
        properties = dict(line.split('=', 1) for line in state.stdout.splitlines() if '=' in line)
        if properties.get('LoadState') == 'masked' or properties.get('DropInPaths'):
            raise InstallError('alist.service 已被屏蔽或存在额外配置，请先处理原服务配置。')
        if properties.get('ActiveState') not in ('inactive', 'failed'):
            raise InstallError('alist.service 尚在运行或状态无法确认，请先执行 systemctl stop alist。')
        with socket.socket() as sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                sock.bind(('0.0.0.0', self.PORT))
            except OSError:
                raise InstallError('端口 5268 无法使用，请先停止占用该端口的程序后重试。') from None
        if self.unit.exists():
            self.previous_unit = self.unit.read_bytes()
        self.previous_enabled = self.systemctl('is-enabled', self.SERVICE, check=False).stdout.strip() == 'enabled'
        architectures = {'x86_64': 'amd64', 'aarch64': 'arm64', 'arm64': 'arm64',
                         'armv7l': 'arm-7', 'armv6l': 'arm-6', 'i386': '386', 'i686': '386'}
        machine = platform.machine()
        if machine not in architectures:
            raise InstallError(f'暂不支持的 CPU 架构：{machine}')
        self.arch = architectures[machine]

    def ask_password(self):
        try:
            with open('/dev/tty', 'w') as terminal:
                while True:
                    password = getpass.getpass('设置管理员密码（至少 8 位）：', stream=terminal)
                    confirmation = getpass.getpass('再次输入管理员密码：', stream=terminal)
                    if len(password) < 8:
                        print('密码至少需要 8 位。', flush=True)
                    elif password != confirmation:
                        print('两次密码不一致，请重新输入。', flush=True)
                    else:
                        return password
        except (OSError, EOFError):
            raise InstallError('需要交互终端输入密码，请保存脚本后在终端执行 bash install-alist.sh。') from None

    def fetch(self, url, destination):
        for attempt in range(3):
            try:
                request = urllib.request.Request(url, headers={'User-Agent': 'Alist-5268-Installer'})
                with urllib.request.urlopen(request, timeout=30) as response, destination.open('wb') as output:
                    shutil.copyfileobj(response, output)
                return
            except (OSError, urllib.error.URLError):
                if attempt == 2:
                    raise InstallError('下载失败，请检查服务器到 GitHub 的连接及 CA 证书。') from None
                time.sleep(2)

    def download(self, stage):
        print('正在下载 Alist 官方最新稳定版…', flush=True)
        self.fetch(self.RELEASE, stage / 'release.json')
        release = json.loads((stage / 'release.json').read_text())
        name = f'alist-linux-{self.arch}.tar.gz'
        asset = next((a for a in release.get('assets', []) if a.get('name') == name), None)
        if not asset:
            raise InstallError(f'官方发布中没有找到 {name}。')
        expected = asset.get('digest') or ''
        if not re.fullmatch(r'sha256:[0-9a-f]{64}', expected):
            raise InstallError('官方发布缺少 SHA-256 校验值，安装已停止。')
        url = asset['browser_download_url']
        if not url.startswith('https://github.com/AlistGo/alist/releases/download/'):
            raise InstallError('下载地址不是预期的官方发布地址。')
        archive_path = stage / 'alist.tar.gz'
        self.fetch(url, archive_path)
        digest = hashlib.sha256()
        with archive_path.open('rb') as archive:
            for chunk in iter(lambda: archive.read(1024 * 1024), b''):
                digest.update(chunk)
        if digest.hexdigest() != expected.split(':', 1)[1]:
            raise InstallError('SHA-256 校验失败，安装已停止。')
        with tarfile.open(archive_path, 'r:gz') as archive:
            member = next((m for m in archive.getmembers()
                           if m.name in ('alist', './alist') and m.isfile()), None)
            if member is None:
                raise InstallError('安装包中没有找到 alist 程序。')
            with archive.extractfile(member) as source, (stage / 'alist').open('wb') as output:
                shutil.copyfileobj(source, output)
        (stage / 'alist').chmod(0o755)
        self.run_command([str(stage / 'alist'), 'version'])
        print(f"版本 {release['tag_name']}，SHA-256 校验和程序兼容性检查通过。", flush=True)

    @staticmethod
    def atomic_write(path, content, mode=0o600):
        temporary = path.with_name(path.name + '.tmp-' + uuid.uuid4().hex)
        try:
            temporary.write_bytes(content)
            temporary.chmod(mode)
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)

    def write_config(self, config):
        self.atomic_write(self.target / 'data/config.json',
                          (json.dumps(config, ensure_ascii=False, indent=2) + '\n').encode())

    def api(self, path, payload=None, token=None):
        headers = {'Content-Type': 'application/json'}
        if token:
            headers['Authorization'] = token
        request = urllib.request.Request(f'http://127.0.0.1:{self.PORT}{path}',
                                         data=None if payload is None else json.dumps(payload).encode(),
                                         headers=headers)
        with self.http.open(request, timeout=5) as response:
            result = json.load(response)
        if not isinstance(result, dict) or result.get('code') != 200:
            raise InstallError(f'Alist 接口 {path} 检查失败。')
        return result.get('data')

    def wait_http(self):
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            if self.proc is not None and self.proc.poll() is not None:
                raise InstallError('Alist 初始化进程提前退出。')
            try:
                self.api('/api/public/settings')
                return
            except (OSError, ValueError, InstallError):
                time.sleep(0.5)
        raise InstallError('等待 Alist 在 5268 提供 HTTP 服务超时。')

    def stop_temporary(self):
        if self.proc is not None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=5)
                raise InstallError('Alist 初始化进程未能正常退出。') from None
            finally:
                self.proc = None

    def unit_text(self):
        return f'''[Unit]
Description=Alist
Wants=network-online.target
After=network-online.target
RequiresMountsFor={self.target} {self.media}

[Service]
Type=simple
User=root
WorkingDirectory={self.target}
ExecStart={self.target}/alist server --data {self.target}/data
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
UMask=0077

[Install]
WantedBy=multi-user.target
'''

    def install(self, stage, password):
        self.target.mkdir(mode=0o700)
        self.installed = True
        shutil.copy2(stage / 'alist', self.target / 'alist')
        (self.target / 'data').mkdir(mode=0o700)
        self.media.mkdir(parents=True, exist_ok=True, mode=0o755)
        self.write_config({'force': True, 'scheme': {'address': '127.0.0.1', 'http_port': self.PORT,
                                                    'https_port': -1}, 'log': {'enable': False}})
        # 先离线设置密码，再启动仅监听回环地址的初始化进程。
        self.run_command([str(self.target / 'alist'), 'admin', 'set',
                          '--data', str(self.target / 'data'), '--log-std', '--', password], cwd=self.target)
        with (self.target / 'install-init.log').open('wb') as log:
            self.proc = subprocess.Popen([str(self.target / 'alist'), 'server', '--data', str(self.target / 'data')],
                                         cwd=self.target, stdout=log, stderr=log, start_new_session=True)
        self.wait_http()
        token = self.api('/api/auth/login', {'username': 'admin', 'password': password})['token']
        # 新安装默认要求登录，避免刚挂载的媒体目录被匿名浏览。
        users = self.api('/api/admin/user/list?page=1&per_page=100', token=token)['content']
        guest = next((user for user in users if user['username'] == 'guest'), None)
        if guest is None:
            raise InstallError('无法确认访客账号状态，安装已停止。')
        if not guest.get('disabled'):
            guest['disabled'] = True
            self.api('/api/admin/user/update', guest, token)
        self.api('/api/admin/storage/create', {
            'mount_path': '/', 'driver': 'Local', 'disabled': False, 'enable_sign': True,
            'addition': json.dumps({'root_folder_path': str(self.media), 'show_hidden': False,
                                    'mkdir_perm': '0755', 'thumbnail': False,
                                    'use_ffmpeg': False, 'recycle_bin_path': 'delete permanently'}),
            'remark': '本地媒体目录', 'order_by': 'name', 'order_direction': 'asc'
        }, token)
        self.api('/api/fs/list', {'path': '/', 'page': 1, 'per_page': 1, 'refresh': True}, token)
        print('管理员登录和本地媒体目录读取验证通过。', flush=True)
        self.stop_temporary()
        config = json.loads((self.target / 'data/config.json').read_text())
        config['scheme']['address'] = '0.0.0.0'
        config['log']['enable'] = True
        self.write_config(config)
        if self.previous_unit is not None:
            (self.target / 'previous-alist.service').write_bytes(self.previous_unit)
        self.atomic_write(self.unit, self.unit_text().encode(), 0o644)
        self.unit_changed = True
        self.systemctl('daemon-reload')
        self.service_attempted = True
        self.systemctl('enable', '--now', self.SERVICE)
        self.wait_http()
        self.systemctl('is-active', '--quiet', self.SERVICE)
        self.systemctl('is-enabled', '--quiet', self.SERVICE)
        pid = int(self.systemctl('show', self.SERVICE, '--property=MainPID', '--value').stdout.strip())
        if pid <= 0 or Path(f'/proc/{pid}/exe').resolve() != self.target / 'alist':
            raise InstallError('systemd 运行的程序路径与 /opt/alist/alist 不一致。')
        token = self.api('/api/auth/login', {'username': 'admin', 'password': password})['token']
        self.api('/api/fs/list', {'path': '/', 'page': 1, 'per_page': 1, 'refresh': True}, token)
        print(f'\n安装完成！\n程序：{self.target}\n媒体目录：{self.media}（Alist 首页 /）\n'
              f'访问：http://服务器IP:{self.PORT}\n账号：admin，密码为刚才输入的密码。\n'
              '服务已运行，并已启用开机自启。\n查看状态：systemctl status alist --no-pager\n'
              '重启服务：systemctl restart alist', flush=True)

    def rollback(self):
        self.stop_temporary()
        if self.service_attempted:
            self.systemctl('stop', self.SERVICE)
            self.systemctl('disable', self.SERVICE, check=False)
        if self.unit_changed:
            if self.previous_unit is None:
                self.unit.unlink(missing_ok=True)
            else:
                self.atomic_write(self.unit, self.previous_unit, 0o644)
            self.systemctl('daemon-reload')
            if self.previous_enabled:
                self.systemctl('enable', self.SERVICE)
        if self.installed:
            failed = self.target.with_name('alist.failed-' + time.strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:6])
            self.target.rename(failed)
            print(f'失败现场保留在 {failed}；媒体目录内容保留。', file=sys.stderr)

    def execute(self):
        self.preflight()
        lock_path = self.root / 'run/lock/alist-installer.lock'
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        with lock_path.open('a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise InstallError('已有另一个 Alist 安装程序在运行。') from None
            self.preflight()
            password = self.ask_password()
            self.target.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix='.alist-install-', dir=self.target.parent) as temporary:
                stage = Path(temporary)
                self.download(stage)
                try:
                    self.install(stage, password)
                except BaseException:
                    try:
                        self.rollback()
                    except Exception:
                        print('自动恢复未完成，请检查 systemctl status alist 和 /opt/alist。', file=sys.stderr)
                    raise


def main():
    os.umask(0o077)
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    try:
        Installer().execute()
    except KeyboardInterrupt:
        print('\n安装已取消。', file=sys.stderr)
        return 130
    except (InstallError, OSError, ValueError, KeyError, tarfile.TarError) as error:
        print(f'安装失败：{error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
PY_INSTALLER
