# 🚇 UoT-Forward (UDP-over-TCP 极速隧道穿透面板)

![Version](https://img.shields.io/badge/Version-V1.1.0-blue.svg)
![Bash](https://img.shields.io/badge/Language-Bash-green.svg)
![Platform](https://img.shields.io/badge/Platform-Linux-lightgrey.svg)
![Core](https://img.shields.io/badge/Core-Phantun_v0.8.1-orange.svg)

**UoT-Forward** 是一款基于高性能 Rust 内核 `Phantun` 二次封装的 **UDP 伪装 TCP 穿透面板**。

在跨国网络环境中，原生 UDP 流量（如 Hysteria 2、TUIC、WireGuard）极易遭到国内运营商（ISP）的**精准 QoS 严重限速**，甚至是**无差别的彻底阻断（UDP 封锁）**。

UoT-Forward 通过在客户端将 UDP 数据包伪装并封装成标准的 TCP 流量，强行打通跨国链路；到达目标落地机后，再由服务端拆包还原为纯净的 UDP 数据，完美拯救被封锁的 UDP 代理节点。

---

## ⚡ 核心优势与战术特性

- 🦀 **Rust 级极限性能**：底层采用 `Phantun` 核心，性能损耗远低于传统的 udp2raw。
- 🎭 **无缝 TCP 伪装**：将 UDP 流量包裹在合法的 TCP 握手与数据流中，轻松穿透极其严苛的防火墙和 QoS 策略。
- 🖥️ **全中文交互面板 (TUI)**：告别繁琐的配置文件和晦涩的命令行。一键呼出图形化菜单，支持傻瓜式安装、添加规则、状态监控与服务启停。
- 🚀 **国内双轨极速下载**：针对国内中转机拉取 GitHub 容易卡死的问题，内置了 `ghfast.top` 和 `ghproxy.net` 双加速镜像通道，秒级完成内核部署。
- 🛠️ **多网卡智能适配**：自动探测服务器主网卡接口（Interface），并自动完成底层的 `iptables` NAT 路由与 TUN 虚拟网卡的绑定配置。
- 🗑️ **强迫症级纯净卸载**：提供一键彻底卸载功能。自动清除守护进程、还原 `iptables` 规则并删除所有配置文件，不留任何系统垃圾。

---

## 📦 一键极速部署

请使用 `root` 权限登录您的 Linux 服务器（支持 Ubuntu / Debian / CentOS），并执行以下命令：

```bash
wget -O uot.sh https://ghproxy.net/https://raw.githubusercontent.com/starshine369/UoT-Forward/main/uot-forward.sh && bash uot.sh
```

---

## 🎮 面板使用说明

部署完成后，在任意目录下输入以下命令即可呼出控制台：

```bash
uot-forward.sh
```

*(注意：初次运行脚本会自动安装 `dialog` 依赖以支撑图形化界面。)*

### 🛡️ 典型作战场景部署流程

假设您有一台 **海外落地机 (Server)** 运行着 Hysteria 2 (UDP 端口 443)，但被国内阻断。您还有一台 **国内中转机 (Client)**。

#### 第一步：配置海外落地机 (接收端)
1. 在海外机运行脚本，选择 `[1] 安装 Phantun 内核`。
2. 选择 `[2] 添加端口转发规则` -> 选择 `[作为服务端 (落地机)]`。
3. 按照向导输入：
   * **TCP 监听端口**：例如 `2000` (用于接收来自国内的伪装 TCP 流量)
   * **UDP 目标地址**：输入 `127.0.0.1:443` (您的 Hysteria 2 监听地址)

#### 第二步：配置国内中转机 (发送端)
1. 在国内机运行脚本，选择 `[1] 安装 Phantun 内核` (建议选择国内加速源)。
2. 选择 `[2] 添加端口转发规则` -> 选择 `[作为客户端 (中转机)]`。
3. 按照向导输入：
   * **目标机器 IP**：海外落地机的公网 IP。
   * **目标机器端口**：海外机刚刚设置的 TCP 监听端口 `2000`。
   * **本地暴露 UDP**：例如 `5000`。

#### 第三步：连接您的客户端
现在，跨国链路的 UDP 阻断已被强行打通。您只需要将电脑/手机上的代理客户端（v2rayN, Clash 等），节点地址指向 **国内中转机的 IP : 端口 5000** 即可享受起飞体验！

---

## 💻 极客命令行 (CLI) 模式

对于喜欢自动化的运维老兵，脚本完全支持脱离图形界面的纯参数调用：

```bash
# 查看帮助与所有参数
sudo ./uot-forward.sh --help

# 国内机一键静默安装内核
sudo ./uot-forward.sh --cn install

# 命令行添加服务端规则
sudo ./uot-forward.sh server add --tcp-port 2000 --udp-target 127.0.0.1:443 --name hk_node

# 命令行查看运行状态
sudo ./uot-forward.sh list
```

---
*Break The Wall, Tunnel Through Everything.*
