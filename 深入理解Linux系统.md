# 深入理解 Linux 系统（Ubuntu 版）

> 这不是一份"命令速查表"，而是一本**讲清楚 Linux 为什么这样工作**的教程。
> 每讲到一个概念，都会配上可以立刻敲的命令，**所有命令都标注全称**。
>
> 配套读物：同目录下的《Ubuntu运维指令教程.md》负责"怎么做"，本篇负责"为什么"。
> 建议阅读顺序：**先读本篇建立心智模型 → 再照运维手册敲命令 → 卡住了回来查本篇**。

---

## 目录

| 章节 | 主题 | 你会明白什么 |
|------|------|------------|
| [0](#0-阅读指南) | 阅读指南 | 怎么用这本教程 |
| [1](#1-linux-到底是什么) | Linux 到底是什么 | 内核、发行版、命令行分别是什么 |
| [2](#2-从按下电源到登录) | 启动流程 | 开机那一秒发生了什么 |
| [3](#3-文件系统一切皆文件) | 文件系统 | 为什么 Linux 能把所有东西当文件 |
| [4](#4-用户与权限) | 用户与权限 | 多用户隔离是怎么实现的 |
| [5](#5-进程运行中的程序) | 进程 | 程序怎么变成"活的东西" |
| [6](#6-内存虚拟内存与-oom) | 内存 | 32 位程序怎么用 64 位内存 |
| [7](#7-磁盘与-io-写下去就真的落盘了吗) | 磁盘与 I/O | 为什么删了文件空间没释放 |
| [8](#8-网络从网卡到应用) | 网络 | 一次请求经历了什么 |
| [9](#9-shell-原理一句话怎么变成进程) | Shell 原理 | 管道、重定向、引号到底发生了什么 |
| [10](#10-systemd-服务为什么可靠) | systemd | 服务"开机自启/崩溃重启"的机制 |
| [11](#11-软件包管理) | 软件包管理 | apt 到底做了什么 |
| [12](#12-命令全称总表) | 命令全称总表 | 全称 + 作用 + 示例（核心章节） |
| [13](#13-动手实验清单) | 动手实验 | 5 个实验重现今天的理解 |
| [14](#14-自检问题) | 自检问题 | 检验是否真的懂了 |
| [15](#15-后续学习路径) | 学习路径 | 下一步去哪 |

---

## 0. 阅读指南

**三个约定：**

1. **命令全称**：凡是缩写命令都会写全称，例如 `ls` = `list`。全称表见[第 12 章](#12-命令全称总表)。
2. **概念 → 命令 → 实验**：先讲清是什么，再给命令，最后让你自己敲一遍验证。
3. **本次环境**：Windows 11 + WSL2（Windows Subsystem for Linux 2，Windows 的 Linux 子系统第二版）跑 Ubuntu 24.04。如果你用物理机或云服务器，命令完全一样，只有第 2 章启动流程和第 6 章内存配置略有差别。

**准备环境（30 分钟内可跑起来）：**

```bash
# wsl --install -d Ubuntu-24.04    ← 这条要在 Windows PowerShell 里执行，不是 Ubuntu 里
wsl --list --verbose               # list = list（列出）；--verbose 显示详细信息

# 进入 Ubuntu
wsl -d Ubuntu-24.04

# 更新系统（首次登录建议做一次）
sudo apt update      # apt = Advanced Package Tool（高级包工具）
sudo apt upgrade --full-apt
```

> `sudo` = `superuser do`（以超级用户身份执行）。Ubuntu 默认禁用 root 远程登录和直接交互登录，所有提权都通过 `sudo` 完成，这样每个提权动作都有日志可查。

---

## 1. Linux 到底是什么

### 1.1 一句话定义

**Linux 是一个操作系统内核（Kernel）。** 它不是完整系统，只是一层"翻译官"：把应用程序的请求翻译成硬件动作，并把硬件的响应用一种统一的接口暴露给程序。

```
        ┌─────────────────────────────────────────────┐
        │  用户空间 (User Space)   ← 你平时用的所有东西     │
        │  Shell(命令解释器) / 编译器 / 数据库 / nginx /  │
        │  Node.js / Python / 桌面环境 / 你写的脚本        │
        └───────────────────┬─────────────────────────┘
                            │  系统调用 (System Call)
        ┌───────────────────▼─────────────────────────┐
        │  内核空间 (Kernel Space)  ← Linux 本体        │
        │  进程调度 / 虚拟内存 / 文件系统 / 网络协议栈    │
        │  设备驱动 / 中断处理 / 安全权限                 │
        └───────────────────┬─────────────────────────┘
                            │  读写寄存器、访问硬件
        ┌───────────────────▼─────────────────────────┐
        │  硬件 (Hardware)  CPU / 内存 / 磁盘 / 网卡      │
        └─────────────────────────────────────────────┘
```

**为什么要分两层？** 因为"运行任意代码"和"控制硬件"不能混在一起。如果应用程序能直接指挥 CPU，那恶意程序就能格式化你的硬盘、读别人的内存。Linux 用**特权级（privilege level）**把两者隔开：只有内核运行在 ring 0，普通程序在 ring 3，越权访问硬件会被 CPU 直接抛异常。

应用程序想用硬件，唯一方式是"请求内核帮忙"，这个请求通道就叫**系统调用（System Call）**：

```bash
# 你以为你在"读文件"，其实是内核在代劳
cat /etc/hostname

# 等价视角：strace = system call trace（系统调用追踪），看内核到底被调用了什么
sudo strace -f cat /etc/hostname 2>&1 | grep openat
```

你会看到类似 `openat(AT_FDCWD, "/etc/hostname", O_RDONLY)` ——你的 `cat` 根本没碰磁盘，它只是请内核："帮我打开 `/etc/hostname`，只读。"

### 1.2 发行版（Distribution）

Ubuntu = Linux 内核 + 一堆配套的东西：

```
Ubuntu = Linux 内核              ← 真正干活的
      + GNOME 桌面 + 终端模拟器   ← 你看到的界面
      + apt 软件包管理 + dpkg     ← 装软件的机制
      + systemd + 网络配置        ← 开机到能用的那一套
      + 数万个人类维护的软件包     ← 相当于 Windows 上的应用商店 + 安装包集合
```

> 你可以在 WSL 里直接验证：`wsl --list --online` 列出所有可安装的发行版。常见发行版有 Ubuntu、Debian（apt 的祖宗）、Fedora（dnf/yum）、Arch（pacman）、openSUSE。

**为什么同一台 Linux 机器可以装不同发行版？** 因为内核只规定了"系统调用怎么用"，至于用什么包管理、怎么配置服务，是发行版自己的选择。这就是"只依赖内核 ABI 稳定"带来的自由。

### 1.3 命令行不是"落后"

GUI（图形界面）的本质是**一个前端调用一个后端程序**：

| 你点的鼠标动作 | 背后其实执行的程序 | 你在终端里该敲的 |
|---------------|------------------|------------------|
| 文件管理器里改权限 | `chmod` | `chmod 755 file` |
| 系统设置里改主机名 | `systemd` 的 hostname API | `hostnamectl set-hostname x` |
| 软件商店装 Node | `apt` | `sudo apt install nodejs` |
| 活动监视器看进程 | `top` 的图形版 | `htop` |
| 右键"在终端打开" | 启动 `gnome-terminal` | 其实你已经在用了 |

**结论**：图形界面能做的，命令行都能做，且更快、更精确、可自动化。运维工作用命令行，是因为服务器大多**根本没有桌面环境**（省内存、省 CPU、减少攻击面）。

### 1.4 Shell 是什么

`Shell` 在中文里常译"外壳"，但它的本意是**"贝壳"**——套在内核外面的一层壳。

Shell 的工作循环是四步：

```
读入一行 → 拆分成 token（词元）→ 做展开替换 → 执行 → 把结果打印回来 → 循环
```

```bash
# echo = 模拟参数，printf = print formatted（按格式打印）
# 下面是"把输出交给下一个命令"的写法：| 是管道
echo $HOME | tr 'a-z' 'A-Z'
# tr = translate（字符转换），把 $HOME 的值转成大写
```

**Shell 不是内核，也不是命令本身。** `ls`、`grep`、`nginx` 是独立的**可执行文件**，Shell 只是负责"找到它、给它参数、等待它、把它的输出接住"。这个理解非常关键，理解了这一点，你就明白为什么：

- 命令可以随便组合（因为它们约定"从标准输出读东西，往标准输出写东西"）
- `ls` 自己都不知道输出会被谁接走
- `sudo` 只是一个普通的"替身程序"，它以 root 身份重新启动 `ls`

---

## 2. 从按下电源到登录

这一章解释"开机时 Linux 到底做了什么"，对应命令 `systemd-analyze`、`systemctl`。

### 2.1 完整启动链

```
按下电源
   │
   ├─ 1. UEFI/BIOS 固件               ← 主板上的第一段程序，选择从哪块磁盘启动
   ├─ 2. GRUB (GRand Unified Bootloader)   ← 引导加载器
   │     GRUB = GRand Unified Bootloader
   │     它读 /boot/grub/grub.cfg，显示启动菜单，选一个内核
   │     屏幕上的 GNU GRUB 界面就是它
   ├─ 3. 内核 (kernel) 启动            ← 压缩的 vmlinuz 解压
   │     初始化：探测 CPU、解析内核命令行、挂载 /proc 和 /sys
   │     内核启动过程中绝大部分是"idle"，因为用户态还没准备好
   ├─ 4. initramfs (initial RAM file system)
   │     一个临时的小型根文件系统（现代 Ubuntu 是 UEFI 引导时读 EFI stub）
   │     作用：还没挂载真磁盘，就能找到并加载磁盘上的真实磁盘驱动
   │     驱动加载完成后，initramfs 就被丢弃了
   ├─ 5. systemd 成为 PID = 1
   │     PID = Process ID（进程编号）。1 号进程是"所有进程的祖先"
   │     systemd 接管一切：拉起服务、管理依赖关系、处理崩溃重启
   ├─ 6. systemd 拉起目标 (target)
   │     graphical.target（有桌面）/ multi-user.target（服务器常用）/ rescue.target
   └─ 7. getty → 登录提示符 → bash → 你的命令
```

### 2.2 验证你的理解

```bash
# systemd-analyze = system boot analyzer（系统启动分析器）
systemd-analyze                          # 看总启动耗时
systemd-analyze blame                    # blame = 归咎，指出最耗时的服务
systemd-analyze critical-chain           # critical chain（关键路径），最慢的依赖链
systemd-analyze plot > boot.svg          # 画成时间线图

# systemctl = system control（系统控制），服务管理的唯一正规入口
systemctl is-system-running              # 运行状态：running / degraded（部分失败）/ maintenance
systemctl get-default                    # 开机默认进入哪个 target

# 看 PID 1 是谁——永远应该是 systemd
ps -p 1 -o pid,comm,args
# -p = --pid（指定 PID）；-o = --output（自定义输出列）；comm = command（命令名）
```

> **WSL 特别注意**：WSL 没有 UEFI/GRUB/BIOS 这套流程。WSL 里的 systemd 是被微软的 `init` 进程启动的，如果你看到 PID 1 是 `init` 而不是 `systemd`，说明还没在 Windows 的 `%UserProfile%\.wslconfig` 里打开 `[wsl2] systemd=true`。

### 2.3 systemd 的"重启即好"

传统 SysVinit（老 Ubuntu，16.04 以前）的思路是：开机顺序从上到下逐个执行服务，一个失败后面全卡死。

systemd 的思路是**依赖图 + 并行 + 自动重试**：

```
network-online.target.target
        │（依赖，等网络真的可用）
        ▼
   nginx.service  ──┐
        │（依赖）  ├── 并行启动，谁也不等谁
   app.service   ──┘
        │（都完成后）
        ▼
   multi-user.target（到达这个 target 才算"开机完成"）
```

```bash
# 只看依赖关系
systemctl list-dependencies nginx.service
# list = list（列出）

# 精确看某个服务单元文件
systemctl cat nginx.service      # cat = concatenate（连接输出）
# cat 单元文件是 systemctl 的"把配置文件打印出来"版本，比自己 find 靠谱
```

---

## 3. 文件系统：一切皆文件

### 3.1 为什么能"一切皆文件"

Linux 的设计哲学：**把一切资源（普通文件、目录、键盘输入、进程信息、网络连接、硬件状态）都抽象成"能 open、能 read、能 write 的文件"**。

于是下面这些荒谬但真实的事情变得正常：

```bash
# 你正在读的这条命令：echo 是程序，| 把输出给 cat，cat 再输出给 less
# 中间那个 /proc/cpuinfo 是个"由内核实时生成的假文件"，它的大小永远是 0，
# 但内容随读随生成
cat /proc/cpuinfo | less

# 关机：读这个"文件"就是在通知内核关机
cat /dev/urandom | head -c 16    # urandom = 随机数设备，random = 随机
```

这套统一抽象由**虚拟文件系统（VFS，Virtual File System）**实现。VFS 在内核里定义了一套接口：任何文件系统只要实现"打开、读、写、关闭"这几个函数就能挂到系统上。所以 ext4、xfs、ntfs、tmpfs、procfs、nfs、overlayfs 全都长得一样，命令完全通用。

**当前挂载了哪些文件系统：**

```bash
findmnt                          # find mount（查找挂载点），比 mount 输出好看
lsblk -f                         # list block devices（列出块设备）+ 文件系统类型
df -hT                           # disk free（磁盘空间），-T 显示文件系统类型

# 你会看到这些类型，各有用途：
# ext4        物理磁盘的标准文件系统（Extended File System 4）
# tmpfs       内存文件系统（Temporary File System），关机即消失
# proc        内核伪文件系统，暴露进程和内核状态
# sysfs       设备伪文件系统
# overlayfs   容器技术（Docker）的基石：把多个目录"叠加"成一个
```

> **overlayfs 值得知道**：Docker 镜像分层、WSL2 的一部分，都靠它。它的逻辑是"底层只读，上层可写，写时复制（Copy-On-Write）"。理解它，你就理解了为什么容器启动快、镜像看起来只有一个文件却有几百兆。

### 3.2 目录结构（FHS）

Linux 目录是一棵**从 `/` 开始的倒着的树**。规范叫 FHS（Filesystem Hierarchy Standard，文件系统层次标准）。

```
/                        根目录，唯一入口
├── /home        （或 /user） 普通用户的家目录  ← 你的私人空间
│   └── yourname
│       ├── ~/.bashrc       交互式 Bash 的配置（别名、PATH）
│       ├── ~/.profile      登录时读一次
│       └── ~/.bash_history 命令历史
├── /etc                   系统级配置文件  ★ 最常去的地方
│   ├── /etc/passwd         用户账号信息（不含密码）
│   ├── /etc/shadow         用户密码哈希（只有 root 能读）
│   ├── /etc/group          组信息
│   ├── /etc/os-release     发行版信息
│   ├── /etc/hosts          本地主机名 → IP 的静态映射（绕过 DNS）
│   ├── /etc/hostname       本机主机名
│   ├── /etc/fstab          ★ 开机自动挂载表
│   ├── /etc/nginx/         Nginx 配置目录
│   ├── /etc/systemd/       服务单元文件目录
│   └── /etc/apt/           软件源配置
├── /var                   ★ "运行时会变化的数据"（variable）
│   ├── /var/log/           日志（你的项目排障 90% 在这）
│   ├── /var/www/           网站根目录
│   └── /var/lib/           服务状态数据（如 docker 镜像）
├── /tmp                   临时文件，★ 机器重启清空（不要放重要数据）
├── /proc                  ★ 进程与内核状态的实时视图（不是真文件）
├── /sys                   设备与驱动的实时视图
├── /dev                   设备文件（hard disk 磁盘设备）
│   ├── /dev/sda            第一块物理磁盘
│   ├── /dev/null           黑洞，扔进去的东西永久消失
│   ├── /dev/zero           无限个 0 字节
│   └── /dev/random         随机数（阻塞式，慢但更随机）
├── /root                  root 用户的家目录
├── /usr (Unix System Resources)  绝大多数程序装在这
│   ├── /usr/bin            大部分命令（bin = binary）
│   ├── /usr/sbin           系统管理命令（s = system）
│   ├── /usr/lib            库文件（library）
│   ├── /usr/local          ★ 手动装的软件放这里，不受包管理器干扰
│   └── /usr/share          共享数据（文档、图标、时区）
├── /opt                   第三方独立安装的软件包
├── /mnt 和 /media          挂载 U 盘、光驱的地方
└── /bin → /usr/bin, /sbin → /usr/sbin   （历史遗留软链接）
```

**核心记忆点（背这五个就够了）：**

| 目录 | 一句话 | 你什么时候会来这里 |
|------|--------|------------------|
| `/etc` | 配置文件 | 改服务配置 |
| `/var` | 会变的数据 | 看日志 |
| `/home` | 用户数据 | 放自己的项目 |
| `/tmp` | 临时垃圾 | 编译中间产物、临时下载 |
| `/usr` | 程序本体 | 找命令在哪个文件 |

### 3.3 路径的语法

```bash
pwd                    # print working directory（打印当前目录）

/                       根目录，只有这一个
.                       当前目录（current directory）
..                      上一级目录（parent directory）
~                       当前用户的家目录（home directory）
~/project               = /home/yourname/project
$HOME                   环境变量形式，同上
```

> **常见坑**：新手写脚本时 `/bin/sh: script.sh: 5: cd: 参数太多`，通常是因为变量没加引号：
> ```bash
> DIR="/tmp/my dir"     # 有空格
> cd "$DIR"             # ✅ 加引号
> cd $DIR               # ❌ 被拆成 cd /tmp/my 和 dir 两个参数
> ```
> **规则：只要是变量，就加双引号。**

### 3.4 inode：Linux 文件的真正身份

这是最容易被忽略、但最能体现"Linux 思维"的概念。

在 Linux 里，**文件名不属于文件**。文件真正的身份是一个叫 `inode`（index node，索引节点）的编号，它记录了文件的所有元数据：

```
inode（真实身份）                        dentry（目录里的"名字"）
┌───────────────────────┐               ┌──────────────────────┐
│ 权限 rwxr-xr-x         │  1 : N映射   │  "a.txt" ──────►      │
│ 属主 root:root         │◄─────────────│  "backup.txt" ──►    │
│ 大小 1234 字节         │               │  "link2" ────────►   │
│ 时间戳 × 3             │               └──────────────────────┘
│ 数据块位置             │
└───────────────────────┘
             │ 1
             ▼
       实际数据块（在磁盘上）
```

**由此推出四个重要结论：**

**① 硬链接 = 给同一个 inode 起新名字**

```bash
# ln = link（链接）
ln  a.txt   hard_a.txt      # 硬链接：两个名字，一个 inode
ls -li a.txt hard_a.txt     # -i = inode，显示 inode 号，两者完全相同
# 注意：ln 的第二个参数必须写全路径，否则会在当前目录建链接
```

**② 软链接（符号链接）= 存了一个"路径字符串"**

```bash
ln -s a.txt soft_a.txt     # -s = symbolic（符号化），创建符号链接
ls -li a.txt soft_a.txt     # inode 不同！
cat soft_a.txt              # 读它时会跟随链接，找到 a.txt
rm a.txt                    # 删掉原文件
cat soft_a.txt              # 报错：No such file（断了）
# 所以：硬链接是"两个名字一份数据"，软链接是"一个写着地址的便利贴"
```

**③ 删文件的真相 = 减少 inode 引用计数**

```bash
rm -i big.log              # rm = remove；-i = interactive（交互确认）
# 你以为删了文件，其实只是：1) inode 引用计数 -1；2) 清掉一个目录项
# 只要还有别的名字指向这个 inode，数据就还在

# 日志文件被删了但磁盘没释放的真相：
# ① 进程还开着这个文件 → inode 引用计数不为 0 → 数据不释放
#    ss -tnp | grep nginx     # 找出还占着文件的进程
#    systemctl restart nginx   # 重启后空间立刻释放
# ② 文件已经被 unlink 但进程仍持有 fd（file descriptor，文件描述符）
```

**④ 磁盘快满时，先查 inode 有没有用光**

```bash
df -h      # 看空间
df -i      # -i = inodes，看 inode 数量 ← 小文件超多时会先耗尽 inode
```

### 3.5 挂载：把一棵目录树"嫁接"到另一处

```bash
# mount = 把一个文件系统挂到某个目录上
mount | column -t                   # 只读方式查看所有挂载
findmnt /                           # 看某个挂载点

# 实践：挂载 U 盘
sudo mkdir -p /mnt/usb              # mkdir = make directory
sudo mount /dev/sda1 /mnt/usb
sudo umount /mnt/usb                # umount = unmount（卸载）
# 关键：不用时一定要 umount，否则拔盘会丢数据

# 让开机自动挂载：编辑 /etc/fstab
blkid /dev/sda1                     # 拿 UUID（Universally Unique Identifier）
# UUID="1234-ABCD"  /mnt/usb  ext4  defaults  0  2
# ↑ 必须用 UUID，因为 /dev/sda1 的名字会变，UUID 不会
sudo mount -a                       # -a = all，应用 fstab 所有配置

# WSL 里访问 Windows 文件
cd /mnt/c/Users                     # 9p/plan9 协议，性能很差
# ★ 性能建议：不要在 /mnt/c 下跑 Node 项目，跨系统 IO 极慢，
#   应该复制到 Linux 内部文件系统（如 ~/project）再跑
```

---

## 4. 用户与权限

### 4.1 UID 和 GID：Linux 安全模型的起点

Linux **没有"管理员"这种角色**，只有一个数字：`UID = 0`。UID 为 0 的进程拥有内核级的全部权力。

```
读(read, r=4) 写(write, w=2) 执行(execute, x=1)
权限数字 = r*4 + w*2 + x*1
rwx = 4+2+1 = 7      r-x = 4+0+1 = 5      rw- = 4+2+0 = 6
```

三个用户类别，每类各有一组 rwx：

```
属主 (owner)     属组 (group)     其他人 (others)
   rwx              rwx              rwx
   │                 │                 │
-r-xwxrr--  1  yourname  www  1024  server1.js
 │  │  │     │      │      │     │      └── 文件名
 │  │  │     │      │      │     └───────── 大小（字节）
 │  │  │     │      │      └─────────────── 所属组
 │  │  │     │      └────────────────────── 属主
 │  │  │     └───────────────────────────── 其他人权限
 │  │  └─────────────────────────────── 属组权限
 │  └────────────────────────────────── 属主权限
 └───────────────────────────────────── 文件类型
```

**文件类型那一位：**

| 符号 | 类型 | 全称 | 说明 |
|------|------|------|------|
| `-` | 普通文件 | regular file | `nginx.conf` |
| `d` | 目录 | directory | `nginx/` |
| `l` | 符号链接 | symbolic link | 你自己建的软链接 |
| `c` | 字符设备 | character device | 按字符读，`/dev/null` |
| `b` | 块设备 | block device | 按块读，`/dev/sda` |
| `s` | 套接字 | socket | Nginx 的网络入口 |
| `p` | 命名管道 | named pipe (FIFO) | 进程间通信 |

**所以 `ss -lntp` 输出里那个 `s` 就是 socket**——Nginx 监听的 80 端口，本质是一个文件。

### 4.2 命令全称与实操

```bash
id                                 # print user identity（打印身份）：uid/gid/groups
whoami                             # who am i（我是谁）

# chmod = change mode（修改权限模式）
chmod 755 run.sh                   # 八进制：属主 rwx，属组 r-x，其他人 r-x
chmod u+x run.sh                   # 符号式：u = user，+ = 增加，x = execute
chmod -R 755 dist/                 # -R = recursive（递归），目录树全部
chmod a-w file                     # a = all，去掉所有人的写权限
chmod u+s myscript                 # s = setuid：不管谁执行，都以文件属主身份运行
                                  # ★ 危险：等效于把 root 权限交给这个脚本

# chown = change owner（修改属主属组）
sudo chown -R www-data:www-data /var/www
sudo chgrp -R www-data /var/www

# umask = user file creation mask（新建文件的默认权限掩码）
umask                               # 通常是 0022
# 含义：新文件权限 = 666 - umask = 644；新目录 = 777 - umask = 755
# 算式：666 & ~0022 = 0644
# 改掉它就不用每次 chmod：
# echo 'umask 0027' >> ~/.bashrc
```

> **为什么 `/etc/shadow` 是 `r` 开头且属主是 root？** 密码哈希必须只有 root 能读。任何普通用户能读到 `/etc/shadow`，就能离线爆破所有密码——这是个经典的提权漏洞面。
> ```bash
> sudo ls -l /etc/shadow
> -rw-r----- 1 root root 1234 Mar 12 /etc/shadow
> ```

### 4.3 sudo 与提权

```bash
sudo -u www-data whoami            # -u = --user（指定以谁的身份执行）→ www-data
sudo -i                            # 启动一个 root 的登录 shell（推荐，比 sudo -s 更彻底）
sudo -E some_cmd                   # -E = --preserve-env（保留当前环境变量）
sudo -v                            # 刷新时间戳，之后一段时间不用再输密码
sudo -l                            # -l = --list，列出你被允许执行什么
visudo                             # ★ 编辑 sudoers 只能用这个，禁止直接编辑
```

**为什么不用 root 直接登录？** 三个理由：
1. **可追溯**：日志能精确到"谁在什么时间提权做了什么"
2. **最小权限**：日常操作不用 root，攻击面小
3. **防误操作**：root 没有 rm 确认机制，输错一个路径就完了

### 4.4 用户组与目录的"协作规矩"

运维里最常见的场景：一个目录里有多个人的文件，但需要**共享可写**。

```bash
# groupadd = group add（创建组）
sudo groupadd devteam
sudo usermod -aG devteam alice      # usermod = user modify；-G = 补充组；-a = append（追加，不覆盖）
# ⚠️ 常见错误：写 `usermod -G devteam alice`（缺 -a）会覆盖掉原有组！

sudo chgrp -R devteam /srv/project # 目录属组改成共享组
chmod -R 2775 /srv/project          # 2775：setgid 位，让新建文件自动继承这个组的权限
#                                    ↑ 这个 2 就是 setgid，目录里的新文件自动归 devteam 组

# 特殊组：
#   wheel     —— 可以 sudo 的管理员组
#   sudo      —— 可执行 sudo 的组
#   www-data  —— Nginx/Apache 的运行用户（Ubuntu 的惯例）
#   docker    —— 可以操作 Docker 的用户（等价于 root，慎用）
```

> **`www-data` 是 Ubuntu 的特色设计**：Nginx 不以 root 身份运行，而是以 `www-data` 运行。所以它读不了 `/root` 下的东西——这是有意的安全设计，配置文件放在 `/etc/nginx/` 而不是 `/root/nginx.conf`。

### 4.5 Capabilities：比 sudo 更精细的提权

现代 Linux 有个更细的机制：**capabilities（能力）**。可以把某一个具体能力单独授予程序，而不是给它整个 root。

```bash
sudo setcap cap_net_bind_service=+ep /path/to/binary
# 让某个程序可以绑定 1024 以下端口，但**不能**读文件、改网络配置
# 用途：让非 root 程序绑定 80/443 端口，同时不授予其他任何 root 权力
```

```bash
getcap /usr/bin/ping          # ping 需要 CAP_NET_RAW
getent passwd www-data        # getent = get entries（查数据库），比 grep 解析可靠
```

---

## 5. 进程：运行中的程序

### 5.1 程序 → 进程的转变

**程序（program）是躺在磁盘上的静态文件，进程（process）是正在内存里跑起来的动态实例。**

同一个 `nginx` 二进制文件，可以同时启动 5 个进程，PID 各不相同，内存互相隔离。这就是为什么服务器上 `ps aux | grep nginx` 会看到一堆。

**进程的核心组成：**

```
进程
├── PID (Process ID)          进程编号，PID 1 是 systemd
├── PPID (Parent PID)         父进程编号 —— ★ 决定谁负责回收它
├── 虚拟内存 (Virtual Memory)  ★ 最大的部分，见第 6 章
│   ├── 代码段 text      程序指令，只读，可被多进程共享
│   ├── 数据段 data      全局变量、已初始化变量
│   ├── 堆 heap         运行时动态分配（malloc / new / GC 管理的对象）
│   └── 栈 stack        每次函数调用的局部变量+返回地址，线程私有
├── 打开的文件列表 (fd table)  每个文件一个 fd，0=stdin 1=stdout 2=stderr
├── 信号处理设置              收到 SIGTERM 时该做什么
├── 资源限制 (rlimit)         最多能开多少文件、占多少内存
└── 调度信息                 内核用它决定谁先跑
```

### 5.2 fork + exec：进程是怎么"生出来"的

这是理解 Linux 的关键机制。**Linux 创建进程 = `fork` + `exec` 两步，但用户平时用的是一条命令。**

```
$ ls -la

Shell 内部实际做了：
  ① fork()  ── 复制出一个几乎一模一样的子进程（父子共享只读代码段，省内存）
              子进程得到一个全新 PID，PPID 指向父进程
  ② execve() ── 子进程把内存里的内容全换成 /usr/bin/ls 的内容
              保留 PID、保留打开的 fd（除非加了 O_CLOEXEC）
  ③ wait()  ── 父进程阻塞等待子进程结束，回收它
  ④ 拿到退出码，打印结果，父进程继续读下一条命令

★ 结论1：进程号的分配者不是内核，是父进程。Shell 给子进程发号。
★ 结论2：父进程必须负责回收子进程，否则留下"僵尸进程"。
```

**僵尸进程（zombie）就是这么来的：**

```bash
# 制造一个僵尸（用 Python 演示最直观）
python3 -c "
import os, time
pid = os.fork()          # 用系统调用明确演示 fork
if pid == 0:
    os._exit(0)          # 子进程立刻退出，但不通知父进程 → 变僵尸
time.sleep(30)
"
# 另一个终端：
ps -o pid,ppid,state,comm -p <上面的子进程PID>
# Z 状态 = Zombie，僵尸已经死透了，只剩一行"户口本"记录
# 僵尸本身不占内存，但占 PID。大量僵尸 = PID 耗尽

# 真实场景：Nginx 的 master 进程如果写错了 SIGCHLD 处理，就会攒僵尸
# 排查：
ps -eo pid,ppid,state,comm | awk '$3 ~ /Z/'      # 列出所有僵尸
# 唯一解法：让父进程正确 wait()，或者重启父进程
```

### 5.3 进程状态：R S D Z T

```bash
ps aux                          # aux = a u x
# a = all（含其他用户/无终端的进程）
# u = user-friendly（输出详细的用户列）
# x = 附��也列出没有控制终端的进程（daemon）

ps -eo pid,ppid,state,%cpu,%mem,etime,comm
# e = environment（标准格式）；o = --output（自定义列）
```

| 状态 | 全称 | 含义 | 能不能中断 |
|------|------|------|-----------|
| **R** | Runnable / Running | 正在跑或在就绪队列排队 | 能 |
| **S** | Sleep / Interruptible sleep | 正常等待（等 I/O、等网络） | **能** |
| **D** | Uninterruptible sleep | 卡在不可中断的内核等待（磁盘慢、NFS 挂了） | **不能**，只能等内核恢复 |
| **Z** | Zombie | 已终止，等父进程回收 | 已死 |
| **T** | Stopped | 被 `Ctrl+Z` 暂停 | 能，用 `fg` 恢复 |
| **I** | Idle | 空闲的内核线程 | — |

**D 状态是运维最大的敌人**：进程杀不掉（`kill -9` 无效），日志不动，看起来像死机。通常是磁盘 I/O 打满或网络文件系统（NFS）异常导致。

### 5.4 怎么查进程

```bash
htop                              # 交互式进程查看器，比 top 好用十倍
# 排序：F6 选择字段，P/M 按 CPU/内存排，/ 输入搜索，k 直接杀进程
# 树状视图：F5，显示父子关系

top                               # Table of Processes（进程表格）
# 按 q 退出，按 1 显示每个 CPU 核心，按 M 按内存排序，按 P 按 CPU 排序

ps auxf                            # f = forest（森林），用树形显示父子关系

# 精确定位
pgrep -a node                     # process group grep，按名字找 PID 并显示完整命令行
pkill -f "server1.js"             # 按完整命令行杀进程（-f = --full-command-line）
kill -15 12345                    # 发 SIGTERM，让它自己优雅退出
kill -9 12345                     # SIGKILL，内核直接杀，不给它清理的机会（产生僵尸）

# 内核视角：/proc 里全是文件
ls -l /proc/12345/cwd             # 进程的工作目录（cwd = current working directory）
ls -l /proc/12345/exe             # 可执行文件路径（exe = executable）
cat /proc/12345/status            # 详细的进程状态，等价于 ps 的信息源
cat /proc/12345/limits            # 资源限制（ulimit 的来源）
cat /proc/12345/maps | head       # 内存布局图，虚拟地址 → 实际位置
# ★ 所有 ps/top/htop 的数据，本质都是从 /proc 读出来的
```

### 5.5 负载（load average）到底是什么意思

```bash
uptime
#  15:32:01 up 2days3:14,  1 user,  load average: 0.52, 0.58, 0.59
#                      └ 1分钟 5分钟 15分钟 的平均负载
```

**load 是"正在运行 + 等待运行 + 不可中断等待（D 状态）的任务数"的指数移动平均。**

判断标准要**除以 CPU 逻辑核心数**：

```bash
nproc                              # number of processors，逻辑核心数
# 4 核机器：
# load = 4    → 刚好满载
# load = 1    → 严重空闲
# load = 8    → 严重过载，任务在排队
```

**三个数字的组合告诉你趋势：**

| 1分钟 | 5分钟 | 15分钟 | 结论 |
|-------|-------|--------|------|
| 高 | 高 | 高 | 一直过载，问题持续 |
| 高 | 低 | 低 | **刚出现**，去查刚发生什么（发布？定时任务？攻击） |
| 低 | 高 | 高 | 正在恢复 |

**关键判断：CPU 满不满，不能只看 load。**

```bash
top 中看 %CPU 这一列；或者
mpstat -P ALL 1                    # mpstat = multiprocessor statistics（多处理器统计）
# %usr 高 → 计算密集（代码问题，需要优化算法）
# %sys 高 → 系统调用太多（可能是日志狂打、频繁小 IO）
# %iowait 高 → 卡在等磁盘（D 状态的元凶）
# %idle 高但 load 高 → 负载来自 D 状态或不可中断等待，不是 CPU 不够
```

### 5.6 线程：并发与"线程地狱"

```bash
ps -eLf                      # -L = show threads（显示线程），f = 森林
top -H                       # -H = show threads，按线程显示
ls /proc/12345/task/          # 每个线程一个子目录
```

**两个必须知道的代价：**

1. **共享内存 = 共享一切，包括错误**
   一个线程改了共享变量、没加锁，另一个线程正好在读 → **竞态条件（race condition）**。Node.js 单线程 JavaScript 没这个问题，这就是它的优势；但 Node 的 I/O 是异步的，也一样会乱。

2. **线程数不是越多越好**
   线程切换有成本（保存/恢复寄存器、刷新 TLB）。经验值：**线程数 ≈ 2 × CPU 核心数 + 等待 I/O 的任务数**。

```bash
ulimit -u                     # -u = --processes，最大用户进程数
ulimit -n                     # -n = --open-files，最大打开文件数（默认 1024，Node 高并发很容易撞）
```

> **Node 项目经典故障**：访问量一涨就报 `EMFILE: too many open files`。原因就是 `ulimit -n` 默认 1024，而每个连接 + 定时器 + 日志都占 fd。解决：`sudo systemctl edit --full yourapp` 里加 `LimitNOFILE=65535`，或 `fs.file-max` 全局调大。

---

## 6. 内存：虚拟内存与 OOM

### 6.1 虚拟内存是"骗你的"

**每个进程都以为自己独占了全部内存。** 你在 8GB 的机器上，程序照样按 16TB 地址空间来规划自己的数据结构。真相是内核用三种手段兑现这个承诺：

```
你的代码写：  存数据到变量 x
                    ↓
        CPU 产生的地址是"虚拟地址" 0x7ffd_0000
                    ↓
   ┌────────────────────────────────────────┐
   │  MMU (Memory Management Unit)          │  ← CPU 里的硬件地址翻译器
   │  查页表 (Page Table)：虚拟地址 → 物理地址│     每次访存自动完成
   │  查不到？如果地址合法就分配一页物理内存    │
   │  （页 = page，Linux 默认 4KB）           │
   └────────────────────────────────────────┘
                    ↓
              物理内存 0x8a3f_c000
```

**这样做的三个好处：**

1. **进程隔离**：A 进程越界访问不会踩到 B 的内存（越界会触发段错误 Segmentation fault）
2. **内存超卖 / 按需分配**：程序写了 10GB 但只用 100MB，内核只给它 100MB 物理内存
3. **共享内存成本极低**：两个进程运行同一个程序，代码段是同一份物理内存，**内核直接让两个页表项指向同一物理页**（所以你看到内存只涨了一点）

### 6.2 free -h 的每一列

```bash
free -h                          # free = show free memory（显示空闲内存）
```

```
              total   used   free  shared  buff/cache   available
Mem:            15Gi   8.2Gi   1.1Gi   512Mi        5.9Gi        6.7Gi
Swap:          2.0Gi      0B  2.0Gi
```

| 列 | 全称 | 含义 | 关键理解 |
|----|------|------|---------|
| total | 总物理内存 | 装机的 RAM | 硬件决定 |
| used | 已使用 | 进程真正在用的 + 内核结构占用 | 应用关注这个 |
| free | 完全没用过 | 连缓存都没有的空页 | **free 小不等于内存不足！** |
| shared | 共享内存 | tmpfs、共享库、共享段 | |
| **buff/cache** | 缓冲区 + 页面缓存 | 内存被拿来做文件缓存 | **这是好事，不是浪费** |
| **available** | 还能给新程序用 | free + 可回收的 cache | **判断内存够不够，看这一列** |
| Swap | 交换分区 | 磁盘上冒充内存的空间 | 见下节 |

**关键认知**：Linux 把空闲内存拿去做缓存（读文件时先把数据放内存），需要时立刻"收回"。所以 `free` 很低是**正常且健康**的。**真正的判断标准是 `available`。**

### 6.3 Swap 的真相：不是"内存不够时才用"

```bash
swapon --show                    # swap = swap on（交换分区），--show 显示所有
mkswap /dev/sdb2                 # make swap
swapon /dev/sdb2

free -h
# Swap 用了 → 不代表内存不够！
# 1. 冷页面本来就不该在内存里，放 Swap 是对的
# 2. 内核有 swappiness（默认 60）：
#    vm.swappiness = 10          # 改成 10，更倾向于留在内存
# 3. Swap 用了之后内存够用 → 系统性能完全不受影响
```

**真正致命的判断标准：Swap 在持续上涨，而且内存的 `available` 在持续下降。** 这是内存泄漏的信号。

### 6.4 OOM Killer：Linux 为什么突然杀掉你的程序

```bash
dmesg -T | grep -i "killed process"       # dmesg = display message，-T 显示可读时间
journalctl -k | grep -i oom
```

**流程：**

```
系统分配内存失败 → 内核 OOM Killer 介入
   ↓
按"oom_score" 挑一个进程杀掉换出内存
   ↓
优先杀：占用内存最多的 → 进程数最多的 → oom_score_adj 最高的
   ↓
杀掉后，内存释放，其他进程继续
```

**这个机制很坑的地方**：它可能杀掉的是 MySQL 而不是某个泄漏的小程序。所以生产环境要调 `oom_score_adj`：

```bash
# 给重要进程设成"尽量别动我"（-1000 表示绝不主动被杀）
echo "-1000" | sudo tee /proc/$(pgrep -d, mysqld)/oom_score_adj
# 持久化在 systemd 单元里写：
#   OOMScoreAdjust=-1000
```

### 6.5 内存泄漏的排查

```bash
# 1. 找内存占用 Top 10（RSS = Resident Set Size，常驻内存大小）
ps aux --sort=-rss | head -11 | awk '{printf "%-8s %-10s %s\n", $6/1024"MiB", $11, $12}'

# 2. 持续观察趋势（最关键：看的是"是否一直涨"）
watch -n 5 'ps aux --sort=-rss | head -6'
# watch = 定期执行并刷新屏幕；-n 5 = 每 5 秒

# 3. 看虚拟内存 vs 常驻内存（VSZ 远大于 RSS = 可能申请了但没用完的虚拟内存）
ps aux | awk '{print $1, $4, $5, $6, $11}' | head

# 4. 内核视角：这个进程的内存占用热点
sudo cat /proc/PID/status | grep -E "VmRSS|VmSize"
sudo cat /proc/PID/smaps_rollup      # -rollup 汇总版，看 Pss（实际分摊内存）

# 5. 堆分析（Node/Java）
node --inspect app.js                # 启动调试端口，用 Chrome DevTools 连
# 或 heapdump：node --heapsnapshot-signal=SIGUSR2
```

**Node 内存三巨头：**

```bash
node --max-old-space-size=4096 app.js    # 调整 V8 堆上限（MB）
# 三个内存上限，默认值老旧了：
#   --max-old-space-size   V8 老生代堆
#   --max-semi-space-size  新生代（大对象/频繁小对象时影响 GC 性能）
#   --max-old-space-size 参数名就是字面意思

NODE_OPTIONS="--max-old-space-size=4096 --max-semi-space-size=64" npm start
```

**WSL 的额外坑**：WSL 会把 Windows 的内存占用算进去，导致 `.wslconfig` 里的 `memory` 上限计算奇怪。解决办法是在 `free -h` 里**只看 `available` 列**，或者干脆在 WSL 里跑的时候手动设 `swap`。

---

## 7. 磁盘与 I/O：写下去就真的落盘了吗

### 7.1 写文件的四层缓存

```
你的 write() 调用
   ↓
① 进程自己的缓冲区（用户空间）—— 不太常见
   ↓
② ★ 页面缓存 Page Cache（内核空间）—— 内存！数据在这里
   ↓  ← 这一层让"写成功"返回得非常快
③ 磁盘缓存（硬盘自己的小缓存，SSD 有 DRAM）
   ↓
④ 真正的物理盘片 / NAND
```

```bash
# 这就是为什么：写完立刻拔电会丢数据，dd 的进度条瞬间跑完
dd if=/dev/zero of=test.img bs=1M count=1000 oflag=direct
# bs = block size（块大小）；count = 写多少块
# oflag=direct 绕过页面缓存，直接打到磁盘 —— 想测真实磁盘性能必须加
# ⚠️ 注意：在 / 目录下 dd 1TB 能把整台机器的盘写满

# 手动落盘
sync                                # sync = 同步，把所有缓存写到磁盘
echo 3 | sudo tee /proc/sys/vm/drop_caches   # 丢缓存（仅测试用，危险）
```

**关键结论：**

- `write()` 返回成功 = "数据进了页面缓存"，**不等于**数据在盘上
- `fsync()` = "请内核确保这个文件的数据真的落到盘上"
- **Nginx 用 `proxy_buffering on`（默认）时，回答客户端之前会确保上游响应已经落盘**——这是默认行为，不是意外

### 7.2 为什么删了文件空间不释放

回到第 3.4 节讲过的 inode。完整原因有两个：

```bash
# 情况1：进程还持有文件描述符（最常见）
sudo lsof +L1                     # list open files，+L1 = 显示已删除但仍被占用的文件
# 输出含义：nginx 的 fd 8 指向 /var/log/nginx/access.log (deleted)
# 解决：重启进程

# 情况2：磁盘上有大量被删除但仍被进程占用的大文件
sudo lsof -nP | grep '(deleted)' | awk '{s+=$7} END {print s/1024/1024" MiB"}'
# -n = --numeric（不解析名字，更快）；-P = --port（端口不转服务名）

# 情况3：ext4 的"保留 5% 空间"（默认留给 root 的紧急空间）
sudo tune2fs -l /dev/sda2 | grep -i reserved     # tune2fs = tune extended filesystem
sudo tune2fs -m 0 /dev/sda2     # 改成 0%，但这会失去安全网
#   reserved = 保留空间给 root，防止磁盘满时普通服务彻底瘫痪
#   在 /var/www 那种"必须能用"的场景可以调低，在磁盘紧张时可以清掉
```

### 7.3 I/O 性能观测

```bash
iostat -x 1                       # iostat = I/O statistics；-x = extended（扩展统计）
# 关键列：
#   r/s, w/s     每秒读写次数
#   rkB/s, wkB/s 每秒读写 KB
#   %util        设备忙碌百分比，接近 100% = 饱和
#   await        平均 I/O 等待时间（毫秒）★ 真正决定用户感受的指标

sudo iotop -oP                    # iotop = I/O top，实时看哪个进程在读写；-o 只显示有 IO 的，-P 显示 PID
vmstat 1                          # vmstat = virtual memory statistics；重点看 bi/bo（块设备输入/输出）和 wa（I/O 等待占比）

# 磁盘满了怎么办（顺序很重要）
df -h                             # 1. 先定位哪个挂载点满了
du -sh /var/* | sort -rh | head   # du = disk usage（磁盘占用）；-s 汇总，-h 人类可读，sort -rh 反序
sudo journalctl --vacuum-size=100M # 2. 清 systemd 日志（Ubuntu 最常见的元凶）
sudo apt clean                     # 3. 清 apt 缓存
sudo apt autoremove --purge        # 4. 删无用包（--purge 连配置文件一起删）
```

---

## 8. 网络：从网卡到应用

### 8.1 分层与实际数据包

一次 HTTP 请求，Linux 内核要做的封装：

```
应用：`curl http://example.com`
  │
  │ write() 到 socket
  ▼
第4层 传输层   TCP（Transmission Control Protocol）★ 负责可靠传输
  │            加了：源端口、目标端口、序列号、确认号、控制位
  ▼
第3层 网络层   IP（Internet Protocol）★ 负责跨网段寻址
  │            加了：源 IP、目标 IP、TTL
  ▼
第2层 链路层   Ethernet（以太网）★ 负责同一局域网内的传输
  │            加了：源 MAC、目标 MAC
  ▼
网卡发出电压信号 ─────────────────────────────────────────────►

返回时逐层剥开（解封装），数据回到你的应用。
```

**这个分层的现实意义：**

- **端口是传输层的概念**。所以 "80 端口不通" 和 "IP 不通" 是两个完全不同的问题，排查顺序必须是先 ping IP、再测端口
- **网卡只认 MAC 地址**。跨网段转发时，MAC 每跳都变，IP 不变。这也是为什么 ping 的第一跳之后看不到 MAC
- **DNS 是 UDP/53**（传统 A 记录），所以 DNS 查询不受 TCP 保护，也容易被污染（DoH/DoT 就是为了解决这个）

### 8.2 从命令行验证每一层

```bash
# ── 第3层：IP 通不通 ──
ping -c 4 8.8.8.8                # ping = 用声呐声波命名，不是 acronym
# -c = count（次数）
# 输出解读：ttl=115（Linux 初始 64，每跳 -1，所以走了 64-115? 不对——
#   Windows 初始 128，Linux 初始 64。看到 ttl=115 是 Windows，
#   ttl=53 说明经过了 11 跳。第3节给了目标系统的线索）

traceroute -n 8.8.8.8            # traceroute = trace route；-n = 不反解主机名（快很多）
mtr 8.8.8.8                       # mtr = My Traceroute，整合 traceroute + ping，实时观察丢包点

# ── 名字解析（DNS）──
dig example.com                  # dig = Domain Information Groper
dig +short example.com           # 只要 IP
dig example.com MX               # 查邮件服务器记录
nslookup example.com             # name server lookup，Windows 也有的老工具

# ── 第4层：端口通不通 ★ 排查第一神器 ──
nc -zv 127.0.0.1 3001            # nc = netcat；-z = zero-I/O mode（只测连接）
# 关键区别：
#   nc -z       只测 TCP 三次握手成功（端口有人在听）
#   curl 127.0.0.1:3001  实际发 HTTP 请求，能发现"端口开着但服务不对"
curl -sv http://127.0.0.1:3001  # -v = verbose（详细显示握手过程），-s = silent
curl -I http://127.0.0.1:3001    # -I = HEAD request，只取响应头

# ── 整体配置与状态 ──
ip addr                          # ip = Internet Protocol（iproute2 套件）
# 注意：老命令 ifconfig = interface configuration 已废弃，ip a 才是现在的方式
ip route                         # 查看路由表
ip -br a                          # -b = brief（单行紧凑输出），-r = resolve（解析名字）

ss -tulpn                        # ★ 排查必用
# ss = socket statistics
#   -t = tcp,  -u = udp
#   -l = listening（只看监听）
#   -p = process（显示占用进程）
#   -n = numeric（不解析服务名，快）
# 输出解读（每个字段都有含义）：
#   State   Recv-Q Send-Q Local Address:Port   Peer Address:Port  Process
#   LISTEN  0     128    0.0.0.0:80            0.0.0.0:*         nginx:master
#   ↑       ↑     ↑      ↑                     ↑                  ↑
#   状态    接收队列 发送队列 本地监听地址        对端地址           谁占着
#   ★ 0.0.0.0 = 所有网卡（危险，任何人都能连）
#     127.0.0.1 = 只有本机能连（安全）
#     ★★生产环境一定要把 0.0.0.0 改成 127.0.0.1，除非真的需要对外

sudo lsof -i -P -n | grep LISTEN # lsof = list open files
sudo netstat -tulpn              # netstat = network statistics（net-tools 包，已废弃但还能用）

# ★ 排查"服务连不上"的黄金三连
curl -sv http://127.0.0.1:3001    # 1. 本机直连后端
ss -tlnp | grep 3001             # 2. 端口真的在监听？
sudo tail -f /var/log/nginx/error.log   # 3. 上层代理报什么错
```

### 8.3 防火墙：为什么"本机能连，别的机器连不上"

```bash
sudo ufw status verbose          # ufw = Uncomplicated FireWall（简单防火墙）
sudo ufw allow 80/tcp            # 允许 80
sudo ufw allow from 192.168.1.0/24 to any port 3001    # 只允许内网网段
sudo ufw enable                  # ★ 启用前先 SSH 放行，否则会把自己关在门外

sudo nft list ruleset            # nft = nftables（netfilter 的新一代框架，iptables 的继任者）
sudo iptables -L -n -v           # iptables 老框架，还能用但新系统都换 nft 了
#   -L = list（列出规则），-n = numeric，-v = verbose

# 云服务器还有一层：安全组 / Network ACL，在服务商控制台配，和系统防火墙无关
# ★ 排查"连不上"的三层：云安全组 → ufw → 应用监听地址
```

### 8.4 DHCP 与静态 IP

```bash
# Ubuntu 24.04 用 netplan 配网（老教程里的 /etc/network/interfaces 已过时）
ls /etc/netplan/                # netplan 配置目录，YAML 格式
sudo nano /etc/netplan/01-netcfg.yaml   # nano = 增强版 nano 编辑器，Ctrl+O 保存，Ctrl+X 退出

# 关键两行：
#   renderer: networkd     ← 必须！Ubuntu 24.04 默认不装 NetworkManager，不写这行配置不生效
#   dhcp4: true            ← 动态获取；写 dhcp4: false + addresses 才算静态

sudo netplan try                 # 试应用（会自动回滚，防止把自己断网）
sudo netplan apply               # 正式应用
```

**没有网卡/网络起不来时的救援：**

```bash
sudo systemctl restart systemd-networkd
sudo systemctl status systemd-resolved
# 如果 systemd-resolved 出问题：
sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
# （老系统的坑，24.04 改了路径，先确认实际文件在哪再改）
```

---

## 9. Shell 原理：一句话怎么变成进程

这一章解释你每天在用的语法背后的机制。理解了它，Shell 就不再是"要背的语法"，而是"看得懂的管道"。

### 9.1 完整执行流程

你输入：`echo "hello   world" > file.txt | grep hello`

Shell 按顺序做了 8 件事：

```
① 读入一行（Read）
   → bash 提示符等输入，处理特殊字符

② 解析成 token（Parse）★ 引号在这一步生效
   echo
   "hello   world"      ← 双引号内的空格被保护，成为一个 token
   >
   file.txt
   |
   grep
   hello

③ 展开替换（Expansion）★ 变量/通配符在这一步生效
   $VAR 展开成值；*.txt 展开成实际文件名列表
   ★★ 从左到右依次是：
      花括号 → 变量 → 命令替换 $(...) → 算术 → 通配符 → 引号移除

④ 重定向（Redirection）
   > file.txt   → fd 1 指向 file.txt
   | grep      → stdout 接到 grep 的 stdin

⑤ 管道结构（Pipeline）
   ┌──────────┐  fd1   ┌──────────┐  fd1   ┌──────────┐
   │   echo   │──────►│  grep    │──────►│ file.txt │
   │          │ 管道   │ hello    │      │ (被创建) │
   └──────────┘        └──────────┘      └──────────┘

⑥ fork + exec（每个管道段都是独立进程）
   父进程：bash 本身，一直等着

⑦ 等待 + 取得退出码
   echo $?   → 0 表示成功，非0表示失败
   ★ 每个管道段的退出码，只有最后一个（grep）的会被 bash 拿到

⑧ 打印提示符，进入下一轮
```

### 9.2 标准流与文件描述符

**每个进程启动时自带三个"文件"：**

| fd | 名字 | 全称 | 默认指向 | 用途 |
|----|------|------|---------|------|
| 0 | stdin | standard input | 键盘 | 读 |
| 1 | stdout | standard output | 终端 | 正常输出 |
| 2 | stderr | standard error | 终端 | 错误输出 |
| 3+ | | | 你指定的 | |

**重定向的四个基本形式：**

```bash
command > file          # >  = 覆盖写（危险！会清空原文件）
command >> file         # >> = 追加写
command < file          # <  = 输入重定向（原本从键盘读，现在从文件读）
command 2> file         # 只重定向错误输出
command &> file         # &> = 输出+错误都进文件（bash 专有）
command &>> file        # 追加
command 2>&1            # ★ 2>&1 = 把 stderr 指向 stdout 当前指向的地方
command > file 2>&1    # ★ 顺序很重要！这条是"stdout 和 stderr 一起进 file"
command > file 2>file  # 错误进单独的 file2
```

**最经典的坑：`> file 2>&1` 和 `2>&1 > file` 不一样。**

```
> file 2>&1
  第1步：fd1 → file
  第2步：fd2 → (fd1 现在指向的地方) = file
  结果：两个都进 file ✓

2>&1 > file
  第1步：fd2 → (fd1 现在指向的地方) = 终端
  第2步：fd1 → file
  结果：stderr 进了终端，stdout 才进 file ✗
```

### 9.3 引号的四种语义

```bash
NAME="World"                        # 等号两边不能有空格

echo "$NAME"       # World      双引号：展开变量，保留空格为一个整体
echo '$NAME'       # $NAME      单引号：什么都不展开，纯字面量
echo \$NAME        # $NAME      转义：\$ 让 $ 失去变量含义
echo $HOME         # /root      不加引号：展开 + 分词（有这个坑）
echo "路径: $HOME/project"    # 双引号里可以混合
echo '他说"$NAME"'            # 单引号里双引号没意义
echo $(( 3*7 ))               # 算术展开 = Arithmetic Expansion → 21
echo "$(date)"                # 命令替换 = Command Substitution → 命令的输出
echo `date`                   # 老写法，= 用反引号，不推荐
```

**推荐写成 `${NAME}` 而不是 `$NAME`：**

```bash
NAME=hello
echo $NAMEworld        # ❌ 变量名变成 NAMEworld，输出空
echo ${NAME}world      # ✅ 输出 helloworld
```

### 9.4 变量与环境变量

```bash
# 本地 shell 变量（子进程看不到）
count=10
echo $count

# 导出为环境变量（子进程能看到）
export PATH="$PATH:/usr/local/bin"
# PATH 的含义：从左到右依次去这些目录找命令
echo $PATH | tr ':' '\n'

# 常用环境变量
echo $HOME $USER $SHELL $PWD $?
#   $? 上一条命令的退出码（0 成功）★ 写脚本必用

env | sort                       # 列出全部环境变量
export -p                        # 列出导出的变量（带 declare -x）

# /etc/environment  是系统级环境变量（所有用户）
# ~/.bashrc      交互式 shell 读
# ~/.profile     登录时读一次
# /etc/profile   系统级，所有用户
# ★ PATH 的设置写在这四个地方之一
```

### 9.5 常用 Shell 技巧

```bash
# 快速编辑上一条命令（bash 内置，不是命令）
!!                    # 重复上一条命令
!$                    # 上一条命令的最后一个参数
!^                    # 上一条命令的第一个参数
!nginx                # 最近一条以 nginx 开头的命令
^old^new              # 把上条命令里的 old 替换成 new 重跑
# 历史记录
history                        # list history
history | grep nginx           # 找某条命令的编号
!!:p                           # 只打印不执行（dry run，确认命令对不对）

# 花括号展开（很实用）
mkdir -p /var/log/app/{2026,2027}/{01,02}   # 一次建 4 层
cp server{1,2}.js ./backup/                  # 一次复制两个文件
touch access.log{,.1,.2}                     # 一次创建三个文件

# 条件与逻辑
[ -f /etc/nginx/nginx.conf ] && echo "配置存在"    # [ = test（测试），&& 短路与
[ -d /var/log ] || sudo mkdir /var/log             # || 短路或
! command                                        # 取反
cmd1; cmd2                                      # 顺序执行，不管前一个成败

# 小工具
seq 1 5                        # sequence，输出 1 2 3 4 5
yes | head -5                  # yes 无限输出 y，head 截断（管道威力示例）
time sleep 1                   # time = 计时（注意 time 是关键字不是命令）
nohup cmd &                    # no hangup，退出终端也继续跑
disown -h %1                    # 脱离终端控制
type node                      # 告诉你 node 是别名/内建/哪个文件（比 which 全面）
command -v node                # 如果是真实文件就打印路径（写脚本用这个）
alias ll='ls -alhF'            # alias = 别名
```

### 9.6 脚本入门（能看懂就行）

```bash
#!/bin/bash
# 以 #! 开头，告诉系统用哪个解释器（shebang line = 哈希bang行）

set -euo pipefail
# set = 设置 shell 选项
#   -e  命令失败就退出（errexit）
#   -u  使用未定义变量就报错（nounset）
#   -o pipefail  管道中任一段失败就算失败
# ★ 写生产脚本必写这三行，能避免 90% 的脚本事故

readonly DIR="/opt/app"                    # readonly = 只读，防止误改

if [[ -f "$DIR/config.json" ]]; then       # [[ ]] 是 bash 专用的 test（支持正则和 &&）
    echo "配置存在"
elif [[ -z "${API_KEY:-}" ]]; then        # ${VAR:-default} 为空时用默认值
    echo "警告：API_KEY 未设置" >&2        # >&2 = 写到 stderr
else
    echo "其他情况"
fi

for f in /etc/nginx/*.conf; do             # glob = 通配符展开
    [[ -f "$f" ]] || continue             # 跳过不是文件的
    echo "处理 $f"
done

for ((i=0; i<3; i++)); do                 # C 风格 for 循环
    echo "第 $i 次"
done

declare -A count                          # -A = 关联数组（哈希表），bash 4+
count[nginx]=3
echo "${count[nginx]}"

cleanup() {                               # 函数
    rm -f /tmp/myapp.lock
}
trap cleanup EXIT                          # trap = 陷阱，EXIT 时自动执行（清理必备）

while read -r line; do                     # read -r（-r 防止反斜杠被吃掉）
    echo "行：$line"
done < /var/log/nginx/access.log           # 从文件读
```

```bash
chmod +x deploy.sh          # 加执行权限
bash deploy.sh              # 方式1：用 bash 显式执行（不依赖权限）
./deploy.sh                 # 方式2：直接执行（依赖 shebang 和权限）

bash -n deploy.sh           # -n = noexec（语法检查，不执行）★ 改完先跑这个
sh deploy.sh                # 用 sh 兼容性检查（如果脚本要给别人用）
```

> **bash vs sh 的区别**：Ubuntu 的 `/bin/sh` 现在指向 `dash`（Debian Almquist Shell），POSIX 兼容但功能少。`[[ ]]`、数组、`source` 里的某些语法在 dash 下直接报错。**所以脚本第一行要么写 `#!/bin/bash`，要么只用 POSIX 语法。**

---

## 10. systemd：服务为什么可靠

### 10.1 单元（Unit）的类型

systemd 的所有管理对象都叫"单元"，共 12 种类型，最常用的是 4 种：

| 类型 | 全称 | 用途 | 例子 |
|------|------|------|------|
| `.service` | service | 需要长期运行的进程 | `nginx.service` |
| `.socket` | socket | 监听端口，按需拉起进程 | `docker.socket` |
| `.target` | target | 一组单元的集合，标记"达到某个阶段" | `multi-user.target` |
| `.timer` | timer | 定时触发某个 unit | `logrotate.timer` |

**`.socket` 激活是 systemd 最巧妙的设计**：不用常驻服务，端口先监听（socket 很小），有连接来了才 fork 出真正的服务。平时零内存占用。这就是为什么有些服务"平时进程列表里看不到，一访问就出现了"。

### 10.2 状态机

```
enable ──────────► 自动启动
   │
   └── start ──► active (running) ◄─── restart / reload
                   │  │
       stop ───────┘  │  ┌──── stop
                   ↓  ↓  ↓
              inactive (dead)      failed
                                        │
                                    start + Restart=on-failure
                                        └──── 自动重试
```

```bash
systemctl start nginx          # 立即启动
systemctl stop nginx           # 停止（= stop，SIGTERM 后等）
systemctl restart nginx        # 重启 = stop + start
systemctl reload nginx         # 重载配置，不中断服务 ★ Nginx 的正解
systemctl enable nginx         # 开机自动启动（创建软链接到 target.wants/）
systemctl disable nginx        # 取消开机启动
systemctl enable --now nginx   # enable + start 一起做

systemctl status nginx         # 看状态 ★ 排查第一步
systemctl is-active nginx      # 只返回 active/inactive（脚本里用）
systemctl is-enabled nginx     # 查是否开机自启

systemctl list-units --type=service --state=running     # 列出正在跑的服务
systemctl list-unit-files | grep enabled                # 列出所有已启用的

systemctl daemon-reload        # ★ 改完 .service 文件后必须执行
# daemon-reload = 重让守护进程重新读配置（不是重启服务！）
# 流程：改文件 → daemon-reload → restart 服务，三步都要做
```

**`status` 输出解读：**

```
● nginx.service - A high performance web server and a reverse proxy server
     Loaded: loaded (/lib/systemd/system/nginx.service; enabled; vendor preset: enabled)
     Active: active (running) since Mon 2026-10-14 10:22:31 CST; 4h 21min ago
   Main PID: 1234 (nginx)
      Tasks: 6 (limit: 384)
     Memory: 18.2M
     CGroup: /system.slice/nginx.service
           └─1234 /usr/sbin/nginx -g daemon on; master_process on;
           └─1235 nginx: worker process
```

| 行 | 含义 | 排查价值 |
|----|------|---------|
| Loaded: **enabled** | 开机自启 | 想让它开机跑就要 enabled |
| **Active: active (running)** | 真的在跑 | **failed** 就是起不来，看后面原因 |
| since ... 4h 21min ago | 启动至今 | 频繁重启的话这里时间很短 |
| Main PID: 1234 | **master 进程** | 要 kill 就杀这个 |
| └─1235 worker process | 子进程 | ★ Nginx 是多进程的 master/worker 模型 |
| CGroup | 控制组路径 | 能看到它把哪些子进程归到一起 |
| Tasks: 6 | 线程数 | 线程爆炸时这里会很大 |

### 10.3 写一个服务

```bash
sudo nano /etc/systemd/system/app.service
```

```ini
[Unit]
Description=My Node Application      # description（描述），显示在 status 里
Documentation=https://example.com
After=network-online.target          # After = 顺序依赖，在网络之后启动
Wants=network-online.target          # Wants = 弱依赖，拉起它但不影响自己
# ★ 上面两行必须成对出现，After 只是排序，不保证网络真就绪！

[Service]
Type=simple                          # simple = 主进程就是 ExecStart 那个
User=www-data                        # ★ 绝不写 root，除非确实必要
Group=www-data
WorkingDirectory=/opt/app            # 切到目录再执行（Node 需要，找不到 node_modules）
Environment=NODE_ENV=production       # Environment = 环境变量
EnvironmentFile=/opt/app/.env        # 从文件读环境变量（推荐，不进版本库）
ExecStart=/usr/bin/node /opt/app/server.js    # 启动命令（主进程）
#   ★ 必须用绝对路径！systemd 不加载你的 shell 配置，找不到 nvm 装的 node
ExecReload=/bin/kill -HUP $MAINPID   # reload 时执行的命令
Restart=always                       # always / on-failure / on-abnormal / no
RestartSec=5                         # 重启前等 5 秒（避免疯狂重启打满 CPU）

# 安全加固（生产环境建议全开）
NoNewPrivileges=true                 # 禁止提权
PrivateTmp=true                      # 独立的 /tmp
ProtectSystem=strict                  # 系统目录只读
ProtectHome=true                     # 看不见 /home
ReadWritePaths=/opt/app/data         # 只有这个目录可写

StandardOutput=journal               # 输出进 journald
StandardError=journal

[Install]
WantedBy=multi-user.target           # 哪些 target 启用它
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now app.service
systemctl status app.service
sudo journalctl -u app.service -f    # ★ -u = unit，跟踪这个服务的日志

# 调试 systemd 配置（很有用，能看到所有参数展开后的最终值）
systemd-analyze verify /etc/systemd/system/app.service
systemctl cat app.service            # 看 systemd 实际加载的内容
```

**Nginx 的 master/worker 模型值得单独理解：**

```
master process（master_process on）
  │ 负责：读取配置、绑定 80 端口、管理 worker（不处理请求）
  │
  ├── worker process  #0   ← 处理实际请求
  ├── worker process  #1
  └── worker process  #2
      ★ worker 数量 = CPU 核心数（配置文件里 worker_processes auto）
      ★ master 挂了所有请求立即中断；单个 worker 挂了 master 会立刻重启它，
        其他 worker 不受影响 —— 这就是 Nginx 不需要"热备"也能高可用的原因
```

```bash
cat /proc/$(pgrep -o nginx)/task/*/stat 2>/dev/null | wc -l   # master 的线程数
ps -o pid,ppid,cmd -C nginx                # -C = --command，看父子关系
```

---

## 11. 软件包管理

### 11.1 apt 的三层结构

```
你的命令：sudo apt install nginx
    │
    ▼
apt (Advanced Package Tool)          ← 前端：你敲的命令
    │  解析依赖、决定下载什么、调用 dpkg
    ▼
dpkg (Debian Package)                ← 中层：数据库操作 + 解包安装
    │  真正操作文件系统
    ▼
/var/lib/dpkg/status                  ← SQLite 格式的数据库，记录每个包的状态
/var/lib/dpkg/info/*.list            ← 每个包安装了哪些文件
```

**关键理解**：`dpkg` 不会自动下载依赖，它只认你已经放在 `/var/cache/apt/archives` 里的 `.deb` 文件。`apt` 的价值就是"解决依赖 + 下载"。所以你会遇到经典报错 `dpkg was interrupted` —— 上次安装中途失败了，数据库锁着。

```bash
sudo dpkg --configure -a             # 把没配置完的包配置完（解决 interrupted）
sudo dpkg -l | grep nginx            # -l = list，列出所有包
sudo dpkg -L nginx                   # -L = list files，这个包装了哪些文件
sudo dpkg -S /usr/sbin/nginx         # -S = search，这个文件属于哪个包
sudo dpkg -i package.deb             # -i = install，直接装本地 deb（不解决依赖）
sudo dpkg -r package                 # -r = remove，删除但保留配置文件
sudo dpkg -P package                 # -P = purge，删除连配置一起
```

### 11.2 apt 常用操作

```bash
# 更新索引和升级（三步的区别很重要）
sudo apt update          # ★ 只更新"有哪些新版本"的清单，不动你的系统
sudo apt upgrade         # 升级已安装的包（有依赖变化时可能删除包，谨慎）
sudo apt full-upgrade    # 允许删除冲突的包（发行版大版本升级用它）
sudo apt autoremove --purge    # 删掉不再需要的自动安装的依赖包
# ★★ 重要区别：apt upgrade 不会删除包，dist-upgrade 可能删除。
#    生产环境建议先 update，然后 apt upgrade --dry-run 看会发生什么

# 安装
sudo apt install nginx
sudo apt install -y nginx         # -y = yes，自动确认（脚本里用）
sudo apt install --no-install-recommends nginx    # 只装必需的（镜像瘦身）
sudo apt install --only-upgrade nginx              # 已装的包只升级不重装

# 查询
apt search nginx                 # 搜索包名和描述
apt show nginx                   # show = 显示包的详细信息（版本、大小、依赖）
apt list --installed | grep node
apt list --upgradable            # 哪些可以升级
apt policy                       # ★ 看软件源的优先级和候选版本
apt depends nginx                # 看依赖关系
apt rdepends --installed nginx   # 谁依赖了我

# 卸载
sudo apt remove nginx            # 保留 /etc 下的配置文件
sudo apt purge nginx             # ★ 连配置一起删（重新装就是全新的）

# 软件源
cat /etc/apt/sources.list         # 主源列表（24.04 很多在 sources.list.d/ 里）
sudo add-apt-repository ppa:nginx/stable    # add = 添加第三方源（Personal Package Archive）
ls /etc/apt/sources.list.d/
sudo apt-key ...                 # ★ 已废弃，改用签名文件
# 阿里云/清华镜像（国内加速）：
#   deb https://mirrors.aliyun.com/ubuntu/ noble main restricted universe multiverse
```

**WSL 里 apt 会很慢的解决办法：**

```bash
sudo sed -i 's@//.*archive.ubuntu.com@//mirrors.aliyun.com@g' /etc/apt/sources.list.d/ubuntu.sources
# sed = stream editor（流编辑器）；-i = in-place（原地修改，直接改文件不输出）
sudo apt update
```

### 11.3 apt 的替代品

```bash
snap list                         # Canonical 的通用包管理（Ubuntu 默认自带）
flatpak list                      # Flatpak（跨发行版，GNOME 官方推荐）
snap install node --classic       # --classic 绕过沙箱限制（但更不安全）
```

> **不建议在服务器上用 snap**：它用 squashfs + AppArmor + systemd 套娃，资源占用高、排查问题困难。**服务器就用 apt。**

---

## 12. 命令全称总表

这是本篇的核心参考。**建议打印出来贴在显示器旁边。**

### 12.1 系统信息与硬件

| 命令 | 全称 / 来源 | 作用 | 示例 |
|------|------------|------|------|
| `uname` | Unix name | 内核版本、架构、主机名 | `uname -a`（-a = all） |
| `lsb_release` | Linux Standard Base release | 发行版信息 | `lsb_release -a` |
| `hostname` | host name | 主机名 | `hostname` |
| `hostnamectl` | hostname control | 主机名的 systemd 接口 | `hostnamectl set-hostname x` |
| `uptime` | up time | 开机时长 + 负载 | `uptime` |
| `date` | date | 日期时间 | `date '+%Y-%m-%d %H:%M:%S'` |
| `timedatectl` | time/date control | 时区、时间同步状态 | `timedatectl` |
| `id` | print identity | 用户 ID 和组 | `id` |
| `whoami` | who am i | 当前用户名 | `whoami` |
| `lscpu` | list CPU | CPU 信息 | `lscpu` |
| `nproc` | number of processors | 逻辑核心数 | `nproc` |
| `lsblk` | list block devices | 磁盘分区树 | `lsblk -f` |
| `lspci` | list PCI | PCI 设备 | `lspci -nn`（-nn 显示数字 ID） |
| `lsusb` | list USB | USB 设备 | `lsusb` |
| `lshw` | list hardware | 硬件详情（需 root） | `sudo lshw -short` |
| `dmidecode` | DMI decode | SMBIOS/BIOS 信息 | `sudo dmidecode -t bios` |
| `findmnt` | find mount | 挂载点信息 | `findmnt` |
| `dmesg` | display message | 内核环形缓冲区 | `dmesg -T \| tail` |
| `nvidia-smi` | — | GPU 状态 | `nvidia-smi` |

### 12.2 文件与目录

| 命令 | 全称 / 来源 | 作用 | 关键选项 |
|------|------------|------|---------|
| `ls` | **list** | 列出目录内容 | `-l` long、`-a` all、`-h` human、`-i` inode、`-t` 按时间、`-S` 按大小、`-R` recursive |
| `cd` | **change directory** | 切换目录 | `cd -` 回到上一个目录 |
| `pwd` | **print working directory** | 当前目录 | |
| `mkdir` | **make directory** | 创建目录 | `-p` 递归建父目录（幂等） |
| `rmdir` | **remove directory** | 删空目录 | |
| `cp` | **copy** | 复制 | `-r` recursive、`-a` archive（保留所有属性）、`-i` interactive、`-n` 不覆盖 |
| `mv` | **move** | 移动/重命名 | `-i` 交互、`-n` 不覆盖 |
| `rm` | **remove** | 删除 | `-r` recursive、`-f` force（不报错！慎用）、`-i` 交互、**`-rf` = rm 的"核弹开关"** |
| `ln` | **link** | 建链接 | `-s` symbolic（软链接）、`-f` 强制 |
| `touch` | — | 创建空文件 / 更新时间戳 | `-a` 只改访问、`-m` 只改修改 |
| `stat` | **status** | 详细元数据 | `stat file` |
| `file` | **file** | 判断文件类型 | `file a.txt`（看魔数，不看扩展名） |
| `tree` | tree | 树状显示 | `-L 2` 限深度、`-h` human |
| `realpath` | **real path** | 解析绝对真实路径 | `realpath link`（看链接最终指向） |
| `basename` / `dirname` | base name / dir name | 拆路径 | |
| `dd` | **disk duplicate** | 块级复制/生成镜像 | `bs=` 块大小、`count=` 数量、`if=` 输入、`of=` 输出 |
| `find` | **find** | 递归查找 | `-name -type -size -mtime -exec` |
| `locate` | locate | 查数据库（快但不准） | 需 `sudo updatedb` 更新 |
| `which` | — | 命令在哪（只看 PATH） | |
| `whereis` | where is | 查二进制/文档/man 页 | |
| `type` | — | 判断是别名/内建/文件（最全） | `type -a ls` |

### 12.3 查看文件内容

| 命令 | 全称 / 来源 | 作用 | 关键选项 |
|------|------------|------|---------|
| `cat` | **concatenate** | 输出整个文件 | `-n` 带行号、`-b` 只给非空行加行号、`-A` 显示不可见字符 |
| `tac` | **cat** 反过来 | **倒序**输出 | `tac file`（调试日志神器） |
| `nl` | **number lines** | 带行号输出 | 比 `cat -n` 更好读 |
| `head` / `tail` | 头 / 尾 | 输出前/后 N 行 | `-n 20`、`-f` follow（持续跟踪）★ 排障必备 |
| `less` | "less is more"（致敬 more） | 分页查看（可上下移动） | `-N` 显示行号、`-S` 不折行、`-F` 小文件直接输出、`/xxx` 搜索、`q` 退出 |
| `more` | — | 分页（只能往下） | 已基本被 less 取代 |
| `column` | **column** | 对齐成表格 | `cat file \| column -t`（按空格分列） |
| `xxd` | hex dump | 看二进制内容 | `xxd file \| head`（排查乱码/编码） |
| `strings` | **strings** | 提取二进制里的可打印字符串 | `strings binary \| grep -i url` |

### 12.4 权限与用户

| 命令 | 全称 / 来源 | 作用 |
|------|------------|------|
| `chmod` | **change mode** | 修改权限 |
| `chown` | **change owner** | 修改属主/属组 |
| `chgrp` | **change group** | 只改属组 |
| `umask` | **user file creation mode mask** | 新建文件的默认权限掩码 |
| `chattr` | **change attributes** | 修改文件扩展属性（+i 不可删、+a 只能追加） |
| `useradd` / `userdel` / `usermod` | user add / delete / modify | 用户管理 |
| `groupadd` / `groupdel` / `groupmod` | group add / delete / modify | 组管理 |
| `passwd` | **password** | 改密码 |
| `getent` | **get entries** | 查 passwd/group 数据库（比 grep 可靠） |
| `su` | **switch user**（原为 super user） | 切换用户 |
| `sudo` | **superuser do** | 提权执行 |
| `visudo` | **view sudo**（vi 包装的 sudoedit） | 安全编辑 sudoers |
| `getcap` / `setcap` | get/set capabilities | 细粒度能力管理 |
| `chroot` | **change root** | 切换根目录（容器的基础） |

### 12.5 进程与资源

| 命令 | 全称 / 来源 | 作用 | 关键选项 |
|------|------------|------|---------|
| `ps` | **process status** | 进程快照 | `aux`、`-ef`、`-eo`、`-p PID`、`--sort=-%cpu`、`-L` 线程、`-f` 森林 |
| `top` | **table of processes** | 实时进程（CPU/内存排序） | `P`/`M` 排序、`1` 单核、`q` 退出 |
| `htop` | **enhanced top** | 更好用的交互式 top | `F6` 选列、`F5` 树状、`/` 搜索 |
| `kill` | — | 发信号 | `-15` TERM 优雅、`-9` KILL 强杀、`-HUP` 重载、`-STOP` 暂停 |
| `pkill` | **process kill** | 按名字杀 | `-f` 匹配完整命令行 |
| `pgrep` | **process grep** | 按名字找 PID 并显示命令行 | `-a` 显示完整命令 |
| `killall` | kill all | 按精确进程名杀 | 比 pkill 严格 |
| `nice` / `renice` | — | 调整优先级 | `nice -n 19 cmd`（19 = 最低优先级） |
| `uptime` | — | 负载 | |
| `nohup` | **no hangup** | 退出终端继续运行 | |
| `jobs` / `bg` / `fg` | — | Shell 任务控制 | `Ctrl+Z` 暂停、`bg %1` 转后台、`fg %1` 调回前台 |
| `disown` | — | 脱离终端控制 | |
| `watch` | — | 定期执行命令 | `-n 1` 每秒、`-d` 显示差异（高亮变化）★ 观察趋势神器 |
| `strace` | **system call trace** | 追踪系统调用 | `-f` 跟子进程、`-p PID` 附加、`-e trace=openat` 过滤 |
| `ltrace` | **library call trace** | 追踪库函数调用 | |
| `perf` | performance | 性能剖析 | `perf top`、`perf record` |
| `vmstat` | **virtual memory statistics** | 虚拟内存/IO/CPU 统计 | `vmstat 1` |
| `iostat` | **I/O statistics** | 磁盘 IO 统计 | `iostat -x 1` |
| `mpstat` | **multiprocessor statistics** | 各 CPU 核心 | `mpstat -P ALL 1` |
| `pidstat` | **process statistics** | 按进程看资源 | `pidstat -d 1` |
| `sar` | **system activity report** | 历史性能采样（sysstat 包） | `sar -u 1`、`sar -r`、`sar -q` |
| `iotop` | I/O top | 实时进程 IO | `-o` 只显示有 IO、`-P` 显示 PID |
| `lsof` | **list open files** | 谁开着哪个文件/端口 | `+D dir`、`+L1`（已删除仍占用）、`-i :80` |
| `pmap` | **process memory map** | 进程内存映射 | `pmap -x PID` |
| `lmemusage` | memory usage | 前缀式内存统计 | `lmemusage -p PID`（pmap 套件） |

### 12.6 网络

| 命令 | 全称 / 来源 | 作用 |
|------|------------|------|
| `ping` | 声呐声波（sonar sound） | 测试连通性 + RTT + 丢包 |
| `traceroute` | **trace route** | 路径追踪 |
| `mtr` | **My Traceroute** | traceroute + ping 合并，实时看丢包位置 |
| `ip` | **Internet Protocol** | 现代化网络配置（iproute2 套件） |
| `ip addr` / `ip route` | address / route | 地址 / 路由表 |
| `ifconfig` | **interface configuration** | 老工具，已废弃（装 net-tools 才有） |
| `ss` | **socket statistics** | ★ 端口和连接（替代 netstat） |
| `netstat` | **network statistics** | 老工具，已废弃 |
| `nc` / `ncat` | **netcat** | 端口测试 / 任意 TCP 传输 |
| `curl` | **client URL**（来源有争议） | HTTP 请求（现代首选） |
| `wget` | **web get** | 下载文件（递归、断点续续） |
| `dig` | **Domain Information Groper** | DNS 查询（DNS 界事实标准） |
| `nslookup` | **name server lookup** | DNS 查询（老工具） |
| `host` | — | DNS 查询（简洁版） |
| `dig/nslookup/host` | — | **区别**：dig 查权威+递归，nslookup 查本机缓存，host 只查 A/AAAA |
| `arp` | **Address Resolution Protocol** | IP→MAC 映射表 |
| `tcpdump` | **TCP dump** | 抓包（排网络问题终极手段） |
| `iperf3` | **IP perform** | 测带宽/吞吐 |
| `ip route` | — | 查看路由，`ip route add` 加路由 |
| `ethtool` | **Ethernet tool** | 网卡协商速率、统计 |
| `nmcli` | **NetworkManager CLI** | NetworkManager 命令行（桌面系统用） |
| `ufw` | **Uncomplicated FireWall** | 简易防火墙 |
| `iptables` | **IP tables** | 老防火墙框架 |
| `nft` | **nftables** | 新防火墙框架 |

### 12.7 服务与日志

| 命令 | 全称 / 来源 | 作用 |
|------|------------|------|
| `systemctl` | **system control** | systemd 服务管理 |
| `journalctl` | **journal control** | systemd 日志 |
| `service` | — | 兼容老脚本的封装 |
| `service nginx status` | — | 会自动翻译成 `systemctl status nginx` |
| `logrotate` | **log rotate** | 日志轮转（改名+压缩+删除旧的） |
| `logger` | — | 往 syslog/journald 写一条日志（脚本里告警用） |
| `dmesg` | **display message** | 内核日志 |
| `tail -f` | — | ★ 实时跟踪日志 |
| `grep` | **G**lobal **R**egular **E**xpression **P**rint | 搜索文本 |
| `less +F` | — | 打开日志时自动进入"tail -f"模式 |

### 12.8 磁盘与内存

| 命令 | 全称 / 来源 | 作用 |
|------|------------|------|
| `df` | **disk free** | 分区空间 |
| `du` | **disk usage** | 目录占用（★ df 看"还剩多少"，du 看"用了多少"） |
| `free` | — | 内存 |
| `mount` / `umount` | mount / unmount | 挂载/卸载 |
| `fdisk` / `parted` | — | 分区工具 |
| `blkid` | **block identifier** | 查设备 UUID/类型 |
| `mkfs` | **make filesystem** | 格式化 |
| `fsck` | **file system consistency check** | 检查/修复文件系统 |
| `sync` | — | 把缓存刷到磁盘 |
| `mkswap` / `swapon` / `swapoff` | make/on/off swap | 管理交换分区 |
| `chroot` | **change root** | 切换根目录 |

### 12.9 文本处理三剑客 + 管道

| 命令 | 全称 / 来源 | 作用 | 示例 |
|------|------------|------|------|
| `grep` | **G**lobal **R**egular **E**xpression **P**rint（源自 ed 编辑器命令 `g/re/p`） | 按行搜索 | `grep -rn "proxy_pass" /etc/nginx/`（-r 递归、-n 行号） |
| `sed` | **stream editor**（对标 ed） | 流式替换/增删行 | `sed -i 's/old/new/g' f`（-i 原地） |
| `awk` | 作者名：**A**ho, **W**einberger, **K**ernighan | 按列/模式处理 | `awk '{print $1, $6}' f`、`awk -F: '{print $2}'` |
| `cut` | **cut** | 按分隔符切列 | `cut -d: -f1 /etc/passwd` |
| `sort` | — | 排序 | `sort -k2 -n`、`sort -u` 去重 |
| `uniq` | **unique** | 去重相邻行 | `sort file \| uniq -c \| sort -rn` |
| `tr` | **translate** | 字符转换 | `tr 'a-z' 'A-Z'`、`tr -d '\r'`（去掉 Windows 换行符） |
| `wc` | **word count** | 统计行/词/字节 | `wc -l` |
| `xargs` | **extended arguments** | 把 stdin 变命令行参数 | `find . -name "*.log" \| xargs rm` |
| `tee` | — | 输出到屏幕**同时**写文件 | `cmd \| tee log.txt` |
| `diff` | **difference** | 比较文件 | `diff -u old new`（-u = unified，统一格式） |
| `patch` | — | 应用 diff 生成的文件 | `patch -p1 < fix.diff` |
| `jq` | **JSON query** | 处理 JSON | `jq '.server[0]' conf.json` |
| `column -t` | — | 对齐输出 | `cat f \| column -t` |

**管道组合实战（这些是真正的威力所在）：**

```bash
# 统计 nginx 日志里最常见的 10 个 IP
awk '{print $1}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head -10

# 找占用最大的 10 个目录
du -h / --max-depth=2 2>/dev/null | sort -rh | head -10

# 找出访问最多的 10 个 URL
awk '{print $7}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head -10

# 统计响应状态码分布
awk '{print $9}' /var/log/nginx/access.log | sort | uniq -c | sort -rn

# 找出 5xx 错误请求
awk '$9 ~ /^5/ {print}' /var/log/nginx/access.log | tail -20

# 统计每个 IP 的请求数和传输量（awk 累加）
awk '{cnt[$1]++; bytes[$1]+=$10} END {for (ip in cnt) print cnt[ip], bytes[ip], ip}' \
    /var/log/nginx/access.log | sort -rn | head

# 实时：每秒打印当前连接数（watch + diff 高亮变化）
watch -n 1 -d 'ss -s'

# 从日志里提取时间戳做趋势（每分钟请求数）
awk -F'[' '{print $2}' access.log | cut -d] -f1 | cut -d: -f1,2 | \
    uniq -c | tail -20

# 找出所有"访问了但报错"的 IP
grep ' 5[0-9][0-9] ' access.log | awk '{print $1}' | sort -u

# 一键生成目录大小报表
du -sh /* 2>/dev/null | sort -rh > /tmp/disk_report.txt
```

### 12.10 Shell 与脚本

| 命令 / 语法 | 全称 | 作用 |
|------------|------|------|
| `echo` | — | 输出字符串 |
| `printf` | **print formatted** | 按格式输出（`\n` 需自己写） |
| `test` / `[ ]` / `[[ ]]` | test | 条件判断 |
| `read` | — | 读取输入（`-r` 保留反斜杠、`-p` 显示提示） |
| `alias` / `unalias` | — | 别名管理 |
| `export` | — | 导出为环境变量 |
| `source` / `.` | — | 在当前 shell 执行脚本（不是子进程，变量会留下） |
| `set` | — | 设置 shell 行为 |
| `trap` | trap | 注册退出/信号时的清理动作 |
| `eval` | **evaluate** | 把字符串当命令执行（**安全风险**） |
| `command` | — | 绕过别名/函数，直接用 PATH 里的命令 |
| `exec` | **execute** | 替换当前进程 / 改变文件描述符 |
| `builtin` | — | 列出所有 Shell 内建命令 |

### 12.11 常用选项速查

| 短选项 | 长选项 | 含义 |
|--------|--------|------|
| `-h` | `--human-readable` | 人类可读（1024、1.5K）★ 排查时必加 |
| `-r` / `-R` | `--recursive` | 递归 |
| `-f` | `--force` | 强制（危险！忽略错误）★ `rm -rf` 是事故高发点 |
| `-i` | `--interactive` | 交互确认 |
| `-n` | `--numeric` | 按数字处理 / 显示行号（含义随命令而变） |
| `-a` | `--all` | 全部 |
| `-l` | `--long` / `--list` | 长格式 / 列出（含义随命令而变） |
| `-v` | `--verbose` | 详细输出 |
| `-c` | `--count` | 计数（grep）或字节数（dd） |
| `-p` | `--parent` / `--process` | 父进程 / 显示进程（含义随命令而变） |
| `-e` | `--edit` | 编辑 / 启用（sed 中表示命令） |
| `-g` | `--global` | 全局（sed 中表示所有匹配行） |
| `-o` | `--output` / `--only-matched` | 输出文件 / 只输出匹配部分 |
| `-t` | `--tty` | 终端（不同命令含义不同） |
| `-S` | `--suffix` / 按大小排序 | 后缀 / 按 size 排序 |

**`2>/dev/null` 的含义**：`2` = stderr，`>` = 重定向，`/dev/null` = 黑洞设备。把错误输出丢掉，**用于清理命令的错误噪音**：

```bash
du -sh /* 2>/dev/null            # 忽略"权限不足"的报错
docker ps 2>/dev/null             # 没装 docker 时静默失败
curl -s https://x.com 2>/dev/null | jq .
```

**常见文件名含义：**

| 文件/目录 | 含义 |
|-----------|------|
| `*.log` | log 文件 |
| `*.pid` | PID 文件（存进程编号，防止重复启动） |
| `*.sock` | socket 文件（IPC 用） |
| `*.conf` | configuration（配置） |
| `*.bak` / `*.old` / `*~` | 备份文件 |
| `.service` | systemd 服务单元 |
| `rc` | **run commands**（历史上以 /etc/rc 脚本启动，现在多指 `.rc` 配置文件或容器 runtime config） |
| `init` | 初始化（历史上有 SysVinit 脚本，现在指容器的 entrypoint 构建阶段） |

---

## 13. 动手实验清单

**理论只有在手上过一遍才算懂。** 按顺序做，每个实验都有一个"你会看到什么"。

### 实验 1：看启动流程（2 分钟）

```bash
systemd-analyze blame | head -10          # 哪 10 个服务最慢
systemctl is-system-running
ps -p 1 -o comm=                          # PID 1 是谁
systemctl list-units --type=target --no-pager   # 有哪些 target
```

**看什么**：如果 PID 1 是 `systemd`，说明你在标准 Ubuntu 或已配置 systemd 的 WSL。

### 实验 2：亲手制造并理解僵尸进程（5 分钟）

```bash
# 终端 A
python3 -c "
import os, time
pid = os.fork()
if pid == 0:
    os._exit(0)
print('子进程 PID:', pid)
time.sleep(40)
"

# 终端 B（把下面的 PID 换成上面打印的）
ps -o pid,ppid,state,comm -p <子进程PID>
# 看到 Z (zombie)

# 让父进程退掉，僵尸被 init(systemd) 收养并回收
kill <父进程PID>
ps -p <子进程PID>          # 已经不存在了
```

**看什么**：理解"僵尸 = 已死但没被收尸"，以及"1 号进程是所有孤儿进程的养父"。

### 实验 3：inode 与删除不释放空间（10 分钟）

```bash
sudo fallocate -l 500M /tmp/big.log    # 快速造 500MB 文件
# fallocate = 分配空间（比 dd 快，因为不真的写数据）
ls -li /tmp/big.log                     # 记住 inode 号

# 制造"删除但空间不释放"
tail -f /tmp/big.log &                  # 一个进程一直打开着它
rm /tmp/big.log                          # 删掉
df -h /tmp                               # 空间没释放！
sudo lsof +L1 | grep big.log             # 找出还占着它的进程
kill %1                                  # 杀掉进程
df -h /tmp                               # 空间立刻回来了 ★
```

**看什么**：彻底理解 inode 引用计数，明白为什么"删了文件空间不释放"。

### 实验 4：软链接 vs 硬链接（5 分钟）

```bash
echo "hello" > a.txt
ln    a.txt hard.txt          # 硬链接
ln -s a.txt soft.txt          # 软链接

ls -li a.txt hard.txt soft.txt
# 看：前两个 inode 相同，第三个不同

rm a.txt
cat hard.txt                  # 还在！hello
cat soft.txt                  # 报错 No such file
```

**看什么**：硬链接是"多个名字一个 inode"，软链接是"存路径字符串"。

### 实验 5：端口与连接状态（10 分钟）

```bash
# 后台起一个简单服务
nohup node server1.js > /tmp/s1.log 2>&1 &
sleep 2

ss -tlnp | grep 3001               # 看监听状态，注意是 127.0.0.1 还是 0.0.0.0
curl -sv http://127.0.0.1:3001 2>&1 | head -20    # 完整握手过程
nc -zv 127.0.0.1 3001              # 纯 TCP 握手测试

# 建立长连接，看 ESTABLISHED
curl http://127.0.0.1:3001 &
sleep 30 &                          # 保持连接
ss -tn | grep 3001                  # 看到 ESTAB + Recv-Q/Send-Q

sudo kill %2 2>/dev/null
pkill -f server1.js
```

**看什么**：端口监听、TCP 连接、Recv-Q/Send-Q 队列的含义，串起"服务可用"的完整链条。

### 实验 6：CPU vs I/O 瓶颈（选做）

```bash
# 制造 CPU 密集
yes > /dev/null &                   # 一个吃满单核
# 制造 I/O 密集
dd if=/dev/zero of=/tmp/test bs=1M count=2000 oflag=direct &
top
# 看 %CPU 和 %wa 的区别

kill %1 %2
```

**看什么**：`load` 高但不一定是 CPU 问题，`wa` 高说明卡在磁盘。

---

## 14. 自检问题

**能流畅回答 = 真懂了：**

1. 为什么删了一个 10GB 的日志文件，`df` 显示空间没释放？怎么彻底解决？
2. `load average: 1.5` 在 2 核和 8 核机器上分别意味着什么？
3. `> file 2>&1` 和 `2>&1 > file` 有什么区别？
4. `free -h` 里 `free` 只有 50MB，但 `available` 有 6GB——机器有问题吗？
5. 为什么 `useradd` 之后 sudo 说 "is not in the sudoers file"？
6. Nginx 的 master 进程挂了会怎样？单个 worker 挂了又会怎样？
7. `/etc/shadow` 为什么必须是 `root:root 640`？谁能读？
8. 一个进程在 `top` 里显示 D 状态，你能做什么、不能做什么？
9. 生产环境 `ss -ln` 看到 `0.0.0.0:3001`，风险是什么？应该改成什么？
10. 为什么 systemd 服务里 `ExecStart` 必须用绝对路径？
11. `apt update` 和 `apt upgrade` 有什么区别？为什么生产环境要看 `--dry-run`？
12. 硬链接和软链接的本质区别是什么？（从 inode 角度回答）
13. 服务连不上，你的排查顺序是什么？每一步用什么命令？
14. 为什么 Node 项目在高并发下会报 `EMFILE`？怎么修？
15. 为什么说 `df` 和 `du` 查的结果可能不一样？

**参考答案要点：**

1. inode 引用计数。进程还持有 fd。`sudo lsof +L1 | grep deleted` 找出进程，重启它。
2. 2 核：严重过载（75%）。8 核：很空闲（19%）。判断标准是 load ÷ 核心数。
3. `> file 2>&1` 两个都进文件；`2>&1 > file` 只有 stdout 进文件，stderr 留在终端。
4. 没坏。`free` 低是健康的，缓存可以随时回收。看 `available`。
5. 新建用户没加进 `sudo` 组：`sudo usermod -aG sudo alice`，然后重新登录。
6. master 挂 = 全部请求立即中断。worker 挂 = master 立刻重启它，其他 worker 无影响（连接被优雅关闭）。
7. 只有 root 能读。所以属主必须 root，权限 640。
8. 能：查原因（I/O 打满？NFS 挂了？）。不能：`kill -9` 无效，D 状态不可中断。
9. 任何人都能连上数据库端口，是重大漏洞。改成 `listen 127.0.0.1;`。
10. systemd 不加载 shell 配置，找不到 `~/.nvm` 里的 node。用 `/usr/bin/node` 或 `/etc/profile.d/` 里配好的路径。
11. update 只刷新版本清单（不动你的包），upgrade 才实际升级。生产环境先看会发生什么。
12. 硬链接：同一个 inode 的另一个目录项（`ln`）。软链接：存了路径字符串的新文件（`ln -s`），指向的目标删了就断。
13. 服务状态 → 端口监听（ss）→ 本机 curl 直连 → Nginx 错误日志 → 云安全组/ufw → 从外部 IP 测。
14. `ulimit -n` 默认 1024 被耗尽。`systemctl edit` 加 `LimitNOFILE=65535`。
15. df 统计已分配的块（可能包含已删除但未释放的），du 统计实际占用（含稀疏文件、硬链接重复计算）。

---

## 15. 后续学习路径

**第一阶段：把上面的实验做完**

目标：`systemctl`、`ss -lntp`、`journalctl -u xxx -f`、`df -h`、`free -h`、`ps aux` 这 6 个命令能不查资料用熟。

**第二阶段：Man 手册（比任何教程都准）**

```bash
man ls                     # man = manual
man 3 printf               # 3 = 函数手册章节（1=普通命令 2=系统调用 5=文件格式 8=管理命令）
man fstab                  # 5 = 文件格式类手册
apropos umask              # apropos = about，按关键词搜手册
man -k compress            # -k = keyword 搜索
man ls | less              # ← 这就是最高效的 Linux 学习方式
```

**第三阶段：文本处理**

目标：能用 `awk` 一行统计出"nginx 日志里每个 IP 的请求数和传输量"。这一步做完，你对管道和列处理就通了。

**第四阶段：写脚本自动化**

目标：写一个 `backup.sh`，每天凌晨 3 点把 `/var/log/nginx` 打包、保留 7 天、出错发邮件。这会自然带出定时任务（cron）、权限、日志、进程管理。

```bash
crontab -e                  # cron = Chronos（时间之神），crontab = cron table
# 例：0 3 * * * /opt/backup.sh
#   ┌─┬─┬─┬─┬─┐
#   │ │ │ │ │ └── 分 0-59
#   │ │ │ │ └──── 时 0-23
#   │ │ │ └────── 日 1-31
#   │ │ └──────── 月 1-12
#   │ └────────── 星期 0-7（0和7都是周日）
#   └────────────
```

**第五阶段：深入一个方向**

| 方向 | 建议读的 |
|------|---------|
| 系统底层 | 《深入理解计算机系统》(CS:APP)、Linux 内核文档 `man 7` 系列 |
| 网络 | 《TCP/IP 详细卷》、`man 7 socket`、`man 7 tcp` |
| 运维进阶 | 《鸟哥的 Linux 私房菜》、The Missing Semester (MIT) |
| 容器 | `man namespaces`、Docker 官方文档 |

**推荐免费资源：**

- `man` 手册本身（最权威，且离线可查）
- The Missing Semester of Your CS Education（MIT 公开课，中文字幕）—— Shell、SSH、编辑器、Git 讲得极好
- Arch Wiki（wiki.archlinux.org）—— 深入且中立的 Linux 技术文档
- Ubuntu Server 官方文档（documentation.ubuntu.com）

---

## 附录：15 分钟速查卡

```
===== 排查问题的黄金顺序 =====

1. 服务在跑吗？       systemctl status xxx
2. 端口在听吗？       ss -lntp | grep 端口
3. 本机能连吗？       curl -sv http://127.0.0.1:端口
4. 日志说什么？       journalctl -u xxx -n 50 --no-pager
                      sudo tail -50 /var/log/nginx/error.log
5. 资源够吗？         top / free -h / df -h
6. 上层代理报什么？   sudo tail -f /var/log/nginx/error.log
7. 防火墙拦了吗？     sudo ufw status

===== 内存不够 =====
free -h                              看 available，不是 free
ps aux --sort=-rss | head -10       找出谁在吃
dmesg -T | grep -i oom               看是不是被 OOM 杀了
ps -eo pid,stat,comm | grep 'D'     找 D 状态进程

===== 磁盘满了 =====
df -h                                哪个挂载点满了
du -sh /* 2>/dev/null | sort -rh     谁的目录大
sudo journalctl --vacuum-size=100M   清日志（Ubuntu 元凶）
sudo lsof +L1 | grep deleted         有进程占着已删文件
sudo apt clean && sudo apt autoremove

===== 进程相关 =====
ps aux --sort=-%cpu | head          CPU Top 10
ps aux --sort=-rss | head          内存 Top 10
htop                                 交互式，看趋势
cat /proc/PID/status                内核视角看某个进程
sudo strace -p PID -e trace=openat  它到底在干什么

===== 改配置的标准流程 =====
sudo nano /etc/xxx/xxx.conf         改
sudo nginx -t                       （Nginx 专属）测试语法
sudo systemctl daemon-reload        （systemd 专属）重读配置
sudo systemctl restart xxx          重启
systemctl status xxx && journalctl -u xxx -n 30 --no-pager   验证

===== 危险命令，敲之前停三秒 =====
sudo rm -rf /
sudo rm -rf ~/
sudo chmod -R 777 /
sudo chown -R nobody /
dd if=/dev/zero of=/dev/sda
history | grep 'rm ' | tail         # 手滑了可以先看历史
```

---

## 三份文档怎么配合

| 文档 | 定位 | 什么时候看 |
|------|------|-----------|
| **本篇《深入理解Linux系统》** | 原理与心智模型 | 卡住时想不通为什么 |
| 《Ubuntu运维指令教程.md》 | 操作手册（17 章，含本项目 Nginx 实战） | 直接抄命令 |
| 《学习指南.md》 | Nginx 负载均衡实战 | 做负载均衡练习时 |

**推荐路线**：读完本篇第 1–11 章 → 打开运维手册边敲边练 → 做完运维手册第 14 章的 Nginx 项目 → 回头读本篇第 8 章和第 13 章，你会有"原来如此"的感受。

---