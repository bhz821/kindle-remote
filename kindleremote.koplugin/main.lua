-- kindleremote.koplugin
-- Kindle WiFi 翻页遥控：在 8090 端口提供一个网页 + JSON API。
-- 手机浏览器打开 http://<kindle-ip>:8090/ 即可翻页，不依赖任何外部服务器。
--
-- 实现参考：httpinspector.koplugin（同一套 SimpleTCPServer + /dev/input 无关的
-- 事件广播机制）、frontend/dispatcher.lua 的 page_jmp 定义。

local Device = require("device")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local PORT = 8090
local MAX_REL = 100 -- dispatcher 里 GotoViewRel 的合法范围是 ±100

---------------------------------------------------------------------
-- 遥控页面（由 Kindle 自己发出，同源，所以能读回 JSON）
---------------------------------------------------------------------
local PAGE_HTML = [==[
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover,user-scalable=no">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="theme-color" content="#0b0b0d">
<meta name="format-detection" content="telephone=no">
<title>Kindle 遥控</title>
<style>
  :root{--bg:#0b0b0d;--fg:#e8e6e3;--dim:#8a8783;--next:#2a6df4;--prev:#33333b;--jump:#1b1b20;--ok:#37d67a;--bad:#ff4d4f}
  *{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
  html,body{height:100%;margin:0}
  body{background:var(--bg);color:var(--fg);font-family:-apple-system,BlinkMacSystemFont,"SF Pro SC","PingFang SC",system-ui,sans-serif;
       display:flex;flex-direction:column;padding:calc(env(safe-area-inset-top) + 4px) 12px calc(env(safe-area-inset-bottom) + 12px);
       user-select:none;-webkit-user-select:none;overscroll-behavior:none}
  header{display:flex;align-items:center;justify-content:space-between;padding:8px 4px 10px;font-size:13px;color:var(--dim)}
  #page{font-variant-numeric:tabular-nums;font-size:15px;color:var(--fg)}
  #dot{width:8px;height:8px;border-radius:50%;background:var(--dim);display:inline-block;margin-right:7px;transition:background .18s;vertical-align:middle}
  #dot.ok{background:var(--ok)} #dot.bad{background:var(--bad)}
  .pad{flex:1;display:grid;grid-template-rows:1fr .52fr 1.45fr;gap:10px;min-height:0}
  button{border:none;border-radius:20px;font-size:21px;font-weight:600;color:var(--fg);background:var(--prev);
         letter-spacing:.5px;display:flex;align-items:center;justify-content:center;
         transition:transform .06s ease,filter .1s ease;font-family:inherit}
  button:active{transform:scale(.985);filter:brightness(1.3)}
  #next{background:var(--next);font-size:27px;font-weight:700}
  .row{display:grid;grid-template-columns:1fr 1fr;gap:10px}
  .row button{font-size:16px;font-weight:500;color:var(--dim);background:var(--jump)}
  .hint{font-size:12px;color:var(--dim);text-align:center;padding:8px 0 0;line-height:1.5}
</style>
</head>
<body>
<header>
  <span><span id="dot"></span><span id="status">连接中…</span></span>
  <span id="page">–</span>
</header>
<div class="pad">
  <button id="prev">↑ 上一页</button>
  <div class="row"><button data-n="-10">− 10 页</button><button data-n="10">+ 10 页</button></div>
  <button id="next">下一页 ↓</button>
</div>
<div class="hint">长按按钮 = 连翻</div>
<script>
(function(){
  var dot=document.getElementById('dot'), st=document.getElementById('status'),
      pg=document.getElementById('page');
  function set(s,c){ st.textContent=s; dot.className=c||''; }

  function jump(n){
    return fetch('/api/jump/'+n,{cache:'no-store'})
      .then(function(r){ return r.json(); })
      .then(function(j){
        if(j && j.ok){ set('已翻页','ok'); } else { set(j&&j.error?j.error:'未打开书籍','bad'); }
        setTimeout(refresh,120);
      })
      .catch(function(e){
        var m = e ? (e.name + ': ' + e.message) : '';
        set('连接断开' + (m ? ' · ' + m.slice(0,60) : ''), 'bad');
      });
  }

  var chain=Promise.resolve();
  function queue(n){ chain=chain.then(function(){ return jump(n); }).catch(function(){}); }

  function refresh(){
    fetch('/api/state',{cache:'no-store'})
      .then(function(r){ return r.json(); })
      .then(function(j){
        if(j && j.ok){ pg.textContent=j.page+' / '+j.total; set('就绪','ok'); }
        else { pg.textContent='–'; set('未打开书籍','bad'); }
      })
      .catch(function(e){
        var m = e ? (e.name + ': ' + e.message) : '';
        pg.textContent='–';
        set('Kindle 没响应' + (m ? ' · ' + m.slice(0,60) : ''), 'bad');
      });
  }

  // iOS 12 及更老（iPhone 5s 封顶就是 iOS 12）的 Safari 没有 Pointer Events，
  // 必须退回 touch 事件，否则大按钮点了完全没反应。
  var hasPointer = !!window.PointerEvent;
  var hasTouch = ('ontouchstart' in window);

  function bind(el,n){
    var t=null,on=false;
    function stop(){ on=false; if(t){clearTimeout(t);t=null;} }
    function addStop(ev){ el.addEventListener(ev,stop,false); }
    function start(e){
      if(e && e.cancelable) e.preventDefault();
      on=true; queue(n);
      t=setTimeout(function tick(){ if(!on)return; queue(n); t=setTimeout(tick,450); },500);
    }
    if(hasPointer){
      el.addEventListener('pointerdown',start);
      ['pointerup','pointercancel','pointerleave'].forEach(addStop);
    }else if(hasTouch){
      // 注意不要同时绑 mousedown/touchstart：iOS 会在 touchend 后补发鼠标事件，会翻两页
      el.addEventListener('touchstart',start,false);
      ['touchend','touchcancel'].forEach(addStop);
    }else{
      el.addEventListener('mousedown',start,false);
      ['mouseup','mouseleave'].forEach(addStop);
    }
    document.addEventListener('visibilitychange',function(){ if(document.hidden) stop(); });
  }

  bind(document.getElementById('prev'),-1);
  bind(document.getElementById('next'),1);
  Array.prototype.forEach.call(document.querySelectorAll('[data-n]'),function(el){
    el.addEventListener('click',function(e){ e.preventDefault(); queue(parseInt(el.getAttribute('data-n'),10)); });
  });

  refresh();
  setInterval(refresh,2500);
})();
</script>
</body>
</html>
]==]

---------------------------------------------------------------------
-- 工具
---------------------------------------------------------------------
local function jsonEscape(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    -- 其余控制字符一并转义
    s = s:gsub("[%z\1-\31]", function(c) return string.format("\\u%04x", string.byte(c)) end)
    return s
end

-- 取当前正在阅读的 ReaderUI；文档已关闭时返回 nil
local function getReaderUI()
    local ui = _G.__kindleremote_reader
    if not ui then return nil end
    local ok, n = pcall(function() return ui.document:getPageCount() end)
    if ok and type(n) == "number" then return ui end
    _G.__kindleremote_reader = nil
    return nil
end

-- LuaSocket 的 send 可能只发送一部分，必须循环到全部发完
local function sendAll(client, data)
    local i, n = 1, #data
    while i <= n do
        local ok, _, last = client:send(data:sub(i))
        if ok then
            i = i + ok
        elseif last and last > 0 then
            i = i + last
        else
            return false
        end
    end
    return true
end

local function respond(client, code, ctype, body)
    local reason = (code == 200 and "OK") or (code == 404 and "Not Found") or "Error"
    local out = table.concat({
        "HTTP/1.1 " .. code .. " " .. reason,
        "Content-Type: " .. ctype,
        "Content-Length: " .. tostring(#body),
        "Cache-Control: no-store, no-cache, must-revalidate, max-age=0",
        "Pragma: no-cache",
        "Access-Control-Allow-Origin: *",
        "Connection: close",
        "",
        body,
    }, "\r\n")
    pcall(sendAll, client, out)
    pcall(function() client:close() end)
end

local function respondJSON(client, tbl)
    local parts = {}
    for k, v in pairs(tbl) do
        if type(v) == "number" or type(v) == "boolean" then
            parts[#parts + 1] = string.format('"%s":%s', k, tostring(v))
        else
            parts[#parts + 1] = string.format('"%s":"%s"', k, jsonEscape(v))
        end
    end
    respond(client, 200, "application/json; charset=utf-8", "{" .. table.concat(parts, ",") .. "}")
end

-- 翻页：与 inspector 完全一致的做法 —— nextTick 后广播 GotoViewRel 事件
local function turnPage(n)
    n = tonumber(n) or 0
    if n > MAX_REL then n = MAX_REL end
    if n < -MAX_REL then n = -MAX_REL end
    if n == 0 then return false end
    UIManager:nextTick(function()
        UIManager:sendEvent(Event:new("GotoViewRel", n))
    end)
    return true
end

local function stateInfo()
    local ui = getReaderUI()
    if not ui then
        return { ok = false, error = "未打开书籍" }
    end
    local page, total, title = 0, 0, ""
    pcall(function() page = ui:getCurrentPage() or 0 end)
    pcall(function() total = ui.document:getPageCount() or 0 end)
    local okp, props = pcall(function() return ui.document:getProps() end)
    if okp and type(props) == "table" and props.title then title = props.title end
    return { ok = true, page = page, total = total, title = title }
end

---------------------------------------------------------------------
-- 插件本体
---------------------------------------------------------------------
local KindleRemote = WidgetContainer:extend{
    name = "kindleremote",
}

function KindleRemote:onRequest(data, client)
    local path = data:match("^%u+%s+(%S+)") or "/"
    path = path:gsub("%?.*$", "")

    -- 只有"翻页"才返回 InputEvent（重置待机计时器），让 Kindle 在持续阅读时保持唤醒。
    -- 页面加载 / 状态轮询刻意不重置：否则网页挂在后台轮询，Kindle 永远不会睡，白耗电。
    if path == "/" or path == "/index.html" then
        respond(client, 200, "text/html; charset=utf-8", PAGE_HTML)
        return nil

    elseif path == "/api/state" then
        respondJSON(client, stateInfo())
        return nil

    elseif path == "/api/next" then
        local ok = getReaderUI() ~= nil
        if ok then turnPage(1) end
        respondJSON(client, { ok = ok, error = ok and "" or "未打开书籍" })
        return Event:new("InputEvent")

    elseif path == "/api/prev" then
        local ok = getReaderUI() ~= nil
        if ok then turnPage(-1) end
        respondJSON(client, { ok = ok, error = ok and "" or "未打开书籍" })
        return Event:new("InputEvent")

    elseif path:match("^/api/jump/") then
        local n = tonumber(path:match("^/api/jump/(%-?%d+)$") or "")
        local ok = getReaderUI() ~= nil and n ~= nil and n ~= 0
        if ok then turnPage(n) end
        respondJSON(client, { ok = ok, error = ok and "" or "未打开书籍" })
        return Event:new("InputEvent")

    elseif path == "/api/ping" then
        respondJSON(client, { ok = true, port = PORT })
        return nil

    elseif path == "/api/version" then
        local ok, ver = pcall(function() return require("version"):getNormalizedCurrentVersion() end)
        respondJSON(client, { ok = true, koreader = ok and tostring(ver) or "unknown", plugin = "1.0" })
        return nil
    end

    respond(client, 404, "text/plain; charset=utf-8", "not found: " .. path)
    return nil
end

function KindleRemote:startServer()
    if _G.__kindleremote_server then return end
    local ok_all, err = pcall(function()
        -- 在 Kindle 防火墙上开洞（和 httpinspector 完全一样的做法）
        if Device:isKindle() then
            os.execute(string.format(
                "iptables -A INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT", PORT))
            os.execute(string.format(
                "iptables -A OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT", PORT))
        end

        local ServerClass = require("ui/message/simpletcpserver")
        local self_ref = self
        local srv = ServerClass:new{
            host = "*",
            port = PORT,
            receiveCallback = function(data, client) return self_ref:onRequest(data, client) end,
        }
        local started, serr = srv:start()
        if not started then
            logger.err("KindleRemote: start failed:", tostring(serr))
            return
        end
        _G.__kindleremote_server = srv
        _G.__kindleremote_zmq = UIManager:insertZMQ(srv)
        logger.info("KindleRemote: listening on port " .. PORT)
    end)
    if not ok_all then
        logger.err("KindleRemote: exception in startServer:", tostring(err))
    end
end

function KindleRemote:stopServer()
    pcall(function()
        if _G.__kindleremote_zmq then
            UIManager:removeZMQ(_G.__kindleremote_zmq)
            _G.__kindleremote_zmq = nil
        end
        if _G.__kindleremote_server then
            _G.__kindleremote_server:stop()
            _G.__kindleremote_server = nil
        end
        if Device:isKindle() then
            os.execute(string.format(
                "iptables -D INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT", PORT))
            os.execute(string.format(
                "iptables -D OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT", PORT))
        end
    end)
end

function KindleRemote:init()
    -- 记住当前 ReaderUI，供 /api/state 读取页码
    if self.ui and self.ui.view and self.ui.document then
        _G.__kindleremote_reader = self.ui
    end
    pcall(function()
        if self.ui and self.ui.menu and self.ui.menu.registerToMainMenu then
            self.ui.menu:registerToMainMenu(self)
        end
    end)
    self:startServer()
end

function KindleRemote:addToMainMenu(menu_items)
    menu_items.kindleremote = {
        text = _("Kindle 遥控翻页"),
        sorting_hint = ("more_tools"),
        sub_item_table = {
            {
                text_func = function()
                    return _G.__kindleremote_server and _("服务运行中 (端口 8090)") or _("服务未运行")
                end,
                callback = function() self:startServer() end,
            },
            {
                text = _("停止服务"),
                callback = function() self:stopServer() end,
            },
            {
                text = _("提示：手机浏览器打开 http://本机IP:8090/"),
                callback = function() end,
            },
        },
    }
end

function KindleRemote:onCloseWidget()
    if _G.__kindleremote_reader == self.ui then
        _G.__kindleremote_reader = nil
    end
end

return KindleRemote
