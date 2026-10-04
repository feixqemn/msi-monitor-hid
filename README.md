# MSI Monitor HID

在 macOS 上按 F14，把 MSI 显示器切到 DisplayPort。Karabiner 接收按键，Swift 小工具通过 USB HID 发送切换命令，按键时才运行。

这是为我的 MSI MPG 271QR QD-OLED X50 写的，设备 ID 为 `1462:3FA4`。Mac 需要连着显示器的 USB 接口，单独接视频线无法控制。

## 安装

先安装 [Karabiner-Elements](https://karabiner-elements.pqrs.org/)，打开一次完成设置，并准备好 Xcode Command Line Tools 和 Python 3。然后：

```sh
git clone https://github.com/feixqemn/msi-monitor-hid.git
cd msi-monitor-hid
./install.sh
```

安装脚本会编译程序，并在当前 Karabiner 配置中加入 F14 切换规则。之后按一下 F14 就会切到 DP。

## 命令行

也可以直接调用安装后的程序：

```sh
"$HOME/Library/Application Support/MSIF14DP/msi-f14-dp" dp
"$HOME/Library/Application Support/MSIF14DP/msi-f14-dp" typec
```

`probe` 列出并探测 HID 通信路径，`query` 尝试读取当前输入。切换命令会发送到可写的 report 路径，查询能返回并不代表同一路径能切换输入。

如果切换输入后，显示器的 USB 连接也转给了另一台电脑，Mac 要重新取得 USB 连接后才能继续控制。

卸载运行 `./uninstall.sh`，会移除程序和当前 Karabiner 配置中的 F14 规则。
