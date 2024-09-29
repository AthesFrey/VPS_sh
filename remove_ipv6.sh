#!/usr/bin/env bash
# 指定解释器的方式
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 定义要检查的变量和期望的值
variables=(
  "net.ipv6.conf.all.disable_ipv6"
  "net.ipv6.conf.default.disable_ipv6"
  "net.ipv6.conf.lo.disable_ipv6"
)
desired_value="1"

# 备份原始的 /etc/sysctl.conf 文件
sudo cp /etc/sysctl.conf /etc/sysctl.conf.bak

# 遍历每个变量进行检查和处理
for var in "${variables[@]}"; do
  # 使用 grep 查找非注释的配置行
  if grep -E "^[^#]*\b${var}[[:space:]]*=" /etc/sysctl.conf >/dev/null; then
    # 提取当前变量的值
    current_value=$(grep -E "^[^#]*\b${var}[[:space:]]*=" /etc/sysctl.conf | sed -E "s/^[^#]*\b${var}[[:space:]]*=[[:space:]]*([0-9]+).*$/\1/")
    if [ "$current_value" = "0" ]; then
      # 如果值为 0，修改为 1
      sudo sed -i "s/^\([^#]*\b${var}[[:space:]]*=[[:space:]]*\).*$/\1$desired_value/" /etc/sysctl.conf
      echo "已将 $var 的值从 0 修改为 $desired_value"
    else
      echo "$var 已设置为 $desired_value，无需修改"
    fi
  else
    # 如果变量不存在，添加到文件末尾
    echo "$var = $desired_value" | sudo tee -a /etc/sysctl.conf >/dev/null
    echo "已添加 $var = $desired_value 到 /etc/sysctl.conf"
  fi
done

# 重新加载 sysctl 配置
sudo sysctl -p

# 显示当前的 IPv6 地址（如果有）
ip a | grep inet6
