# S-Hy2 服务器完整重新安装指南

## 🎯 重新安装前准备

### 前置检查
```bash
# 1. 备份现有配置（如果有）
sudo cp -r /etc/hysteria /etc/hysteria.backup.$(date +%Y%m%d_%H%M%S)

# 2. 停止现有服务
sudo systemctl stop hysteria-server.service 2>/dev/null || true

# 3. 清理旧文件
sudo rm -rf /etc/hysteria/*
sudo rm -f /usr/local/bin/s-hy2
```

---

## 🚀 一键重新安装

### 方法1: 使用官方一键安装（推荐）

```bash
# 在服务器上执行
curl -fsSL https://raw.githubusercontent.com/chentiti888/cb/main/quick-install.sh | sudo bash
sudo s-hy2
```

### 方法2: 手动安装

```bash
# 1. 克隆最新代码
cd /opt
sudo git clone https://github.com/chentiti888/cb.git s-hy2
cd s-hy2

# 2. 添加执行权限
sudo chmod +x hy2-manager.sh scripts/*.sh

# 3. 安装
sudo ./install.sh

# 4. 运行
sudo ./hy2-manager.sh
```

---

## 🔧 配置服务（使用自签名证书）

### 步骤1: 配置 Hysteria2 服务

在 `sudo s-hy2` 菜单中选择：
- `2. 快速配置` - 自签名证书自动配置
  - 输入伪装域名（默认：www.microsoft.com）
  - 确认其他配置使用默认值

### 步骤2: 验证服务

```bash
# 检查服务状态
sudo systemctl status hysteria-server.service

# 如果服务正常，应该看到: active (running)
```

### 步骤3: 获取连接信息

```bash
# 在S-Hy2管理界面中选择
# 8. 节点信息

# 会显示:
# - Hysteria2 原生链接 (直接可用)
# - Clash 订阅链接 (需要修复工具)
```

---

## 🔥 使用修复工具修复Clash订阅

### 上传修复工具

```bash
# 从本地上传修复工具到服务器
scp fix-clash-subscription.sh root@your-server:/root/
```

### 运行修复工具

```bash
ssh root@your-server
chmod +x /root/fix-clash-subscription.sh
sudo /root/fix-clash-subscription.sh
```

### 修复结果

工具会自动：
1. ✅ 检测当前服务器IP（your-server-ip）
2. ✅ 从配置文件读取真实密码
3. ✅ 删除错误的订阅文件
4. ✅ 生成新的订阅文件（使用正确的IP）
5. ✅ 提供修复后的订阅链接

---

## 📱 完整客户端配置指南

### Hysteria2 原生客户端

**优势**:
- ✅ 直接使用，无需额外配置
- ✅ 性能最优
- ✅ 完全支持所有功能

**配置步骤**:
1. 复制Hysteria2原生链接
2. 导入到Hysteria2客户端
3. 启用"不安全连接"
4. 测试连接

**示例链接格式**:
```
hysteria2://your-password@your-server-ip:443?insecure=1&obfs=salmander&obfs-password=your-obfs-password&sni=aws.amazon.com#Hysteria2-Server
```

---

### Clash 客户端

**优势**:
- ✅ 支持Windows/Mac/Linux/Android/iOS
- ✅ 强大的分流规则
- ✅ 可视化管理界面

#### Windows/Mac/Linux (Clash Verge Rev)

1. 复制订阅链接: `http://your-server-ip/sub/clash-xxx.yaml`
2. 导入到Clash
3. 在节点配置中启用: `skip-cert-verify: true`
4. 测试连接

**完整配置示例**:
```yaml
proxies:
  - name: "S-Hy2-Server"
    type: hysteria2
    server: your-server-ip
    port: 443
    password: your-password
    obfs: salamander
    obfs-password: your-obfs-password
    sni: aws.amazon.com
    skip-cert-verify: true  # 关键！
    alpn:
      - h3

proxy-groups:
  - name: "🚀 节点选择"
    type: select
    proxies:
      - "S-Hy2-Server"
  - name: "🎯 全球直连"
    type: select
    proxies:
      - "DIRECT"

rules:
  - DOMAIN-SUFFIX,local,🎯 全球直连
  - IP-CIDR,192.168.0.0/16,🎯 全球直连
  - IP-CIDR,10.0.0.0/8,🎯 全球直连
  - GEOIP,CN,🎯 全球直连
  - MATCH,🚀 节点选择
```

#### Android (Clash for Android)

1. 复制订阅链接到剪贴板
2. 打开Clash for Android
3. 点击 "+" → "从剪贴板粘贴"
4. 选择需要的节点类型（选择 Clash）
5. 点击"导入"
6. 在节点详情中启用"不验证根证书"
7. 点击保存并测试

#### iOS (ShadowRocket)

1. 复制订阅链接
2. 打开ShadowRocket
3. 点击类型 →"Hysteria2"
4. 粘贴链接到URL字段
5. 启用"允许不安全连接"
6. 保存并测试
7. 在SNI栏填写: aws.amazon.com

---

### SingBox 客户端

**特点**:
- ✅ 新一代代理工具
- ✅ 支持所有平台
- ✅ 配置简单

#### 配置指南

1. 在SingBox中导入订阅链接
2. 启用TLS验证: 关闭
3. 保存配置并测试

---

## 🛠️ 服务管理命令

### 常用命令

```bash
# 查看服务状态
sudo systemctl status hysteria-server.service

# 启动服务
sudo systemctl start hysteria-server.service

# 停止服务
sudo systemctl stop hysteria-server.service

# 重启服务
sudo systemctl restart hysteria-server.service

# 查看日志
sudo journalctl -u hysteria-server.service -f

# 查看最近20条日志
sudo journalctl -u hysteria-server.service --no-pager -n 20
```

### 检查配置文件

```bash
# 查看Hysteria2配置
sudo cat /etc/hysteria/config.yaml

# 查看连接信息
sudo cat /etc/hysteria/node-info.txt
```

### 修复Clash订阅（IP地址问题）

```bash
# 如果服务正常但Clash订阅无法连接
sudo /root/fix-clash-subscription.sh
```

---

## 🔍 故障排除

### 问题1: 服务启动失败

**检查步骤**:
```bash
# 1. 查看详细错误
sudo journalctl -u hysteria-server.service -n 30

# 2. 检查配置文件
sudo cat /etc/hysteria/config.yaml

# 3. 验证证书文件
ls -la /etc/hysteria/certs/
```

### 问题2: 客户端无法连接

**检查清单**:
```bash
# 1. 检查服务是否运行
sudo systemctl status hysteria-server.service

# 2. 检查端口是否开放
sudo netstat -tuln | grep :443

# 3. 检查防火墙
sudo ufw status | grep 443
# 或
sudo firewall-cmd --list-ports | grep 443

# 4. 测试端口连通性
telnet 47.79.243.217 443
```

### 问题3: Clash订阅链接404

**解决方案**:
```bash
# 1. 检查HTTP服务器
sudo systemctl status nginx

# 2. 检查订阅目录
ls -la /var/www/html/sub/

# 3. 修复Clash订阅（IP地址问题）
sudo /root/fix-clash-subscription.sh
```

### 问题4: 证书验证错误

**客户端操作**:
- Clash: 在配置中添加 `skip-cert-verify: true`
- Hysteria2: 启用"跳过证书验证"选项
- 其他客户端: 寻找类似的选项

---

## 📊 性能优化建议

### 1. 调整带宽限制

```bash
# 编辑配置文件（如果需要）
sudo nano /etc/hysteria/config.yaml

# 修改带宽配置
bandwidth:
  up: 1000 mbps
  down: 1000 mbps

# 重启服务
sudo systemctl restart hysteria-server.service
```

### 2. 优化伪装域名

```bash
# 使用伪装域名来提高连接成功率
# 推荐使用的可靠域名:
# - www.microsoft.com
# - www.apple.com
# - www.amazon.com
# - www.github.com
```

### 3. 启用快速打开

```bash
# 确保配置中有以下设置
fastOpen:
  udp: true
```

---

## 🎯 完整工作流程（推荐）

### 标准配置流程

1. **安装服务**
   ```bash
   curl -fsSL https://raw.githubusercontent.com/chentiti888/cb/main/quick-install.sh | sudo bash
   sudo s-hy2
   ```

2. **选择配置方式**
   - 选项 2: 快速配置（推荐）
   - 使用自签名证书
   - 伪装域名：www.microsoft.com
   - 其他使用默认值

3. **验证服务**
   ```bash
   sudo systemctl status hysteria-server.service
   # 应该显示: active (running)
   ```

4. **上传修复工具**
   ```bash
   scp fix-clash-subscription.sh root@your-server-ip:/root/
   ```

5. **运行修复工具**
   ```bash
   ssh root@your-server-ip
   chmod +x /root/fix-clash-subscription.sh
   sudo /root/fix-clash-subscription.sh
   ```

6. **配置客户端**
   - **Android**: Clash for Android
   - **iOS**: ShadowRocket
   - **PC/Mac**: Clash Verge Rev
   - **Linux**: Clash Meta

7. **测试连接**
   - 导入订阅链接
   - 启用"跳过证书验证"
   - 测试访问

---

## 🎉 安装成功标志

### 服务端检查

- ✅ `systemctl status` 显示 `active (running)`
- ✅ 端口 443 正常监听
- ✅ 日志无错误
- ✅ 证书文件存在

### 客户端检查

- ✅ Hysteria2 原生链接正常工作
- ✅ Clash 订阅链接可访问
- ✅ Clash 客户端可正常连接
- ✅ 代理流量正常通过

---

## 📞 获取帮助

### 诊断工具
```bash
sudo /root/diagnose-service.sh
```

### 查看文档
- 服务器端: `cat /etc/hysteria/node-info.txt`
- GitHub: https://github.com/chentiti888/cb

### 社区支持
- GitHub Issues: https://github.com/chentiti888/cb/issues

---

## 🔒 安全建议

### 1. 定期更换密码
```bash
# 重新配置服务生成新密码
sudo s-hy2
# 选择: 2. 快速配置
```

### 2. 监控服务状态
```bash
# 实时监控日志
sudo journalctl -u hysteria-server.service -f

# 设置日志轮转
sudo nano /etc/hysteria/config.yaml
```

### 3. 备份配置
```bash
# 定期备份配置
sudo cp -r /etc/hysteria /etc/hysteria.backup
```

---

## 📝 配置信息保存位置

### 服务器端
```
/etc/hysteria/config.yaml       # Hysteria2配置
/etc/hysteria/node-info.txt      # 连接信息
/etc/hysteria/certs/           # 证书文件
```

### 客户端订阅链接
```
http://47.79.243.217/sub/clash-xxx.yaml    # Clash订阅
```

---

## 🚀 下一步操作

### 立即执行:

1. **更新服务**: 上传最新工具并修复
   ```bash
   scp fix-clash-subscription.sh root@your-server:/root/
   ssh root@your-server
   sudo /root/fix-clash-subscription.sh
   ```

2. **配置客户端**: 使用修复后的订阅链接

3. **测试连接**: 验证代理功能正常

---

**现在所有工具都已准备好，您可以在服务器端重新安装S-Hy2了！** 🎉