# 🚀 ImmortalWrt for NanoPi R1S H5

> 专为 NanoPi R1S H5 优化的 OpenWrt 固件，解决网络驱动、内存优化等常见问题。

## 📦 固件特性

- ✅ **网络修复**: 完整 RTL8152/RTL8153 驱动，解决 USB 网卡不识别
- ✅ **接口修正**: 明确 LAN=eth0 (近电源), WAN=eth1 (近 USB)
- ✅ **内存优化**: ZRAM + 智能缓存策略，512MB RAM 流畅运行
- ✅ **性能调优**: TCP BBR + CAKE SQM + Flow Offloading
- ✅ **中文界面**: LuCI 完整汉化 + 常用插件预装

## 🔧 默认配置

| 项目 | 值 |
|------|-----|
| 默认 IP | `192.168.10.1` |
| 用户名 | `root` |
| 密码 | `password` |
| LAN 口 | 靠近电源接口 (黑色) 🔌 |
| WAN 口 | 靠近 USB 接口 (蓝色) 🌐 |
| WiFi | 需手动配置驱动 (MT76x2 支持有限) |

## 📥 刷写步骤

### 方法 1: balenaEtcher (推荐)
1. 下载 `*-squashfs-sdcard.img.gz` 固件
2. 解压得到 `.img` 文件
3. 打开 balenaEtcher，选择镜像和 SD 卡
4. 点击 "Flash!" 等待完成

### 方法 2: dd 命令 (Linux/macOS)
```bash
# 1. 确认 SD 卡设备名 (⚠️ 谨慎操作!)
lsblk  # 例如: /dev/sdb

# 2. 刷写固件
sudo dd if=ImmortalWrt-*-squashfs-sdcard.img of=/dev/sdX bs=1M status=progress conv=fsync

# 3. 安全弹出
sync && sudo eject /dev/sdX
