# Kindle 遥控翻页 (kindleremote)

用手机浏览器给 Kindle 翻页。Kindle 没有蓝牙，但只要有 WiFi 就行。

翻页服务直接跑在 Kindle 上的 KOReader 里 —— **不需要电脑、不需要电脑一直开着、不需要任何外部服务器**。

手机打开一个网页就是遥控器：上一页 / 下一页 / ±10 页 / 长按连翻 / 实时页码。

---

## 前提

- 越狱的 Kindle
- 已安装 [KOReader](https://github.com/koreader/koreader)
- 手机和 Kindle 连在同一个 WiFi

---

## 安装

### 方式一：下载仓库

点右上角 **Code → Download ZIP**，解压得到 `kindleremote.koplugin` 文件夹。

### 方式二：git clone

```bash
git clone git@github.com:bhz821/kindle-remote.git
```

### 然后

1. USB 把 Kindle 连电脑，等它挂载成磁盘
2. 把 `kindleremote.koplugin` 整个文件夹拷到：

   ```
   Kindle 磁盘/koreader/plugins/
   ```

3. 安全弹出 Kindle，拔线
4. **完整退出 KOReader 再重新打开**（插件只在启动时扫描，不重启不生效）
5. 打开一本书

---

## 使用

### 1. 查 Kindle 的 IP

Kindle 主页 → 设置 → 设备选项 → Wi-Fi 网络 → 点当前网络 → 显示 IP。

### 2. 手机浏览器打开

```
http://<Kindle的IP>:8090/
```

### 3. 页面

```
● 就绪              266 / 1204
┌────────────────────────────┐
│         ↑ 上一页            │
├─────────────┬──────────────┤
│  − 10 页    │   + 10 页     │
├─────────────┴──────────────┤
│         下一页 ↓            │
└────────────────────────────┘
```

- 顶部小圆点：绿色 = Kindle 有响应，红色 = 没响应
- 右上角实时页码，每 2.5 秒刷新
- **长按按钮 = 连续翻页**（500ms 后开始，每 450ms 一页）

---

## 停止服务

KOReader 菜单 → 工具 → Kindle 遥控翻页 → 停止服务

## 卸载

删掉 `koreader/plugins/kindleremote.koplugin` 整个文件夹即可，不留任何东西。

---

## 已知限制

- **只对 KOReader 生效**，Kindle 原生阅读器不支持
- **Kindle 休眠后遥控失效**，点亮屏幕就恢复
- 没打开书的时候，页码显示"未打开书籍"，翻页会报错（正常）
- 服务随 KOReader 启动，退出 KOReader 就停

---

## ⚠️ 安全提示

这个插件做两件事：

1. 在 Kindle 防火墙上开一个口子（`iptables` 放行 8090 端口）
2. 跑一个**没有密码、没有鉴权**的 HTTP 服务

也就是说：**同一个 WiFi 下的任何设备，只要能访问到你的 Kindle，就能翻你的书。**

- 只在自己家、宿舍这种可信网络里用
- 不要在公司、咖啡馆、机场这些公共网络上开着
- 不用的时候去菜单里"停止服务"

---

## 兼容性

| 项目 | 状态 |
|---|---|
| Kindle Paperwhite 3 + KOReader v2026.07.2 | ✅ 实测通过 |
| iPhone（iOS 13+） | ✅ 实测通过 |
| iPhone 5s（iOS 12） | ✅ 实测通过（自动降级到 touch 事件） |
| 其他 Kindle 型号 | ❔ 理论上可用，未实测 |
| 其他 KOReader 版本 | ❔ `ui/message/simpletcpserver` 接口若变动可能失效 |

---

## 实现说明

服务端用 KOReader 自带的 `ui/message/simpletcpserver`（LuaSocket）起 HTTP 服务，
通过 `UIManager:insertZMQ()` 把它挂进事件循环，翻页则广播 `GotoViewRel` 事件。

```
GET /              遥控页面
GET /api/state     当前页码 / 总页数 / 书名
GET /api/next      下一页
GET /api/prev      上一页
GET /api/jump/N    相对跳转 N 页（N 范围 ±100）
GET /api/ping      存活检测
GET /api/version   KOReader 版本
```

只有翻页接口会返回 `InputEvent` 重置 Kindle 待机计时器，页面加载和状态轮询刻意不重置 ——
否则网页在后台轮询会让 Kindle 永远不休眠，白耗电。

---

## 许可

[AGPL-3.0](LICENSE)，与 KOReader 一致。

翻页的事件广播机制参考了 KOReader 自带的 `httpinspector.koplugin`。
