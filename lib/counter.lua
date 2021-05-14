local cjson = require('cjson')
--local http = require('resty.http')
local resty_consul = require 'consul'
--local pcall = pcall
local json_decode = cjson.decode
local ngx = ngx
local ngx_log = ngx.log
local ngx_err = ngx.ERR
local ngx_info = ngx.INFO
local timer_at = ngx.timer.at
--local ngx_sleep = ngx.sleep

local my_consul = resty_consul:new({
    host = consul_host,
    port = consul_port,
    connect_timeout = (10*1000), -- 10s
    read_timeout = (10*1000), -- 10s
    default_args = {
	token = consul_token
    },
    ssl = false,
    ssl_verify = true,
    sni_host = nil,
})


local _M = {}

-- 初始化Prometheus指标，全局字典对象，initted 已经被初始化标记，looped 已经开始循环标记
function _M.init()
    uris = ngx.shared.uri_by_host
    global_set = ngx.shared.global_set
    global_set:set("initted", false)
    -- global_set:set("looped", false)
    prometheus = require("prometheus").init("prometheus_metrics") 
    metric_get_consul = prometheus:counter("nginx_consul_get_total", "Number of query uri from consul", {"status"})
    metric_latency = prometheus:histogram("nginx_http_request_duration_seconds", "HTTP request latency status", {"host", "status", "scheme", "method", "endpoint"})
end
-- 从consul上拉取k-v数据，先取得 domain内的 域名列表，然后迭代全部域名key内的endpoint值
function _M.sync_consul()
    local args = {
            keys = true,
            dc = "dc1",
            separator = "/",
    }
    local res, err = my_consul:list_keys('domain/', args)
    if not res then
        ngx_log(ngx_err, "consul_get_key error:"..err)
        metric_get_consul:inc(1, {"failed"})
        return false
    else
        metric_get_consul:inc(1, {"succ"})
    end
    local hosts = res.body
    if hosts == nil then
        ngx_log(ngx_err, err)
        return false
    end
    for i=1, #hosts do
        local host = string.sub(hosts[i],8,-2)
        local args_kv = {
            raw = true,
        }
        local get_uri_by_host, err = my_consul:get('/kv/domain/'..host..'/routers', args_kv)
        if not get_uri_by_host then
            ngx_log(ngx_err, err)
            return false
        end
        local uris_json = get_uri_by_host.body
        if not uris_json then
            ngx_log(ngx_err, err)
            return false
        end
        uris:set(host, uris_json)
    end
    return true
end
-- nginx启动后，初次开始同步consul
function _M.first_init()
    local initted = global_set:get("initted")
    if initted == false then
        global_set:set("initted", true)
        local handler
        function handler(premature)
            if not _M.register() then
                ngx_log(ngx_err, "Call register failed!")
                return
            end
            if not _M.sync_consul() then
                ngx_log(ngx_err, "Call sync_consul failed!")
                return
            end
        end
        -- 第一次启动定时器
        local ok, err = timer_at(0, handler)
        if not ok then
           ngx_log(ngx_err, "Call timer_at failed: ", err)
           return
        end
        ngx_log(ngx_info, "First initialize load consul data!")
    end
end
-- 开始循环定时拉取consul数据
function _M.loop_load()
    local loop_handler
    -- premature 表示nginx 的slave进程的状态（例如nginx平滑reload时，子进程可能存在未完全退出）
    function loop_handler(premature)
        ngx_log(ngx_info, "Timer prematurely expired: ", premature)
        ngx_log(ngx_info, "Worker exiting: ", ngx.worker.exiting())
        if not premature then
            if _M.sync_consul() then
                -- 拉起定时器
                local ok, err = timer_at(delay, loop_handler)
                if not ok then
                    ngx_log(ngx_err, "Call timer_at failed: ", err)
                    return
                end
                ngx_log(ngx_err, "Looping in timer!")
            end
        else
            global_set:set("looped", false)
        end
    end
    -- 绑定到第一个进程上，防止重复拉起定时器
    if global_set:get("looped") == false then
        if 0 == ngx.worker.id() then
            local ok, err = timer_at(delay, loop_handler)
            if not ok then
                ngx_log(ngx_err, "Call timer_at failed: ", err)
                return
            end
            global_set:set("looped", true)
            ngx_log(ngx_err, "Starting loop load consul data!")
        end
    end
end
function _M.log()
    _M.first_init()
    -- _M.loop_load()
    local request_host = ngx.var.host
    local request_uri = ngx.unescape_uri(ngx.var.uri)
    local request_status = ngx.var.status
    local request_scheme = ngx.var.scheme
    local request_method = ngx.var.request_method
    local get_all_hosts = uris:get_keys()
    if get_all_hosts == nil then
        ngx_log(ngx_err, "Dict is empty！")
        return
    end
    for j=1, #get_all_hosts do
        if get_all_hosts[j] == request_host then
            local def_uri = json_decode(uris:get(get_all_hosts[j]))
            if def_uri == nil then
                ngx_log(ngx_err, "Decode uris err!")
                return
            end
            for k=1, #def_uri do
                local s = "^"..def_uri[k].."$"
                if ngx.re.find(request_uri, s, "isjo" ) ~= nil then
                    metric_latency:observe(ngx.now() - ngx.req.start_time(), {request_host, request_status, request_scheme, request_method, def_uri[k]})
                    return
                end
            end
        end
    end
end

function _M.capture(cmd, raw)
    local f = assert(io.popen(cmd, 'r'))
    local s = assert(f:read('*a'))
    f:close()
    if raw then return s end
    s = string.gsub(s, '^%s+', '')
    s = string.gsub(s, '%s+$', '')
    s = string.gsub(s, '[\n\r]+', ' ')
    return s
end

function _M.register()
    local myIP = _M.capture("ifconfig |grep -w inet |awk '{print $2}' |sed 's/^addr://g'|egrep -v '^(172|127)'|head -n 1", false)
    local register_body = '{"ID":"nginx-'..myIP..'-9145","Name":"nginx","Tags":["openresty"],"Address":"'..myIP..'","Port":9145}'
    local res, err = my_consul:put('/agent/service/register', register_body)

    if not res then
        ngx.log(ngx.ERR, err)
	return false
    end

    return true
end

function _M.deregister()
    local myIP = _M.capture("ifconfig |grep -w inet |awk '{print $2}' |sed 's/^addr://g'|egrep -v '^(172|127)'|head -n 1", false)
    local res, err = my_consul:put('/agent/service/deregister/nginx-'..myIP..'-9145', '')

    if not res then
        ngx.log(ngx.ERR, err)
        local msg = 'service "nginx-'..myIP..'-9145" deregister failed!'
        ngx.say(msg)
    else
        local msg = 'service "nginx-'..myIP..'-9145" deregister successed!'
        ngx.say(msg)
    end
end

function _M.get_consul()
    local args = {
            keys = true, 
            dc = "dc1", 
            separator = "/",
    }
    local res, err = my_consul:list_keys('domain/', args)

    if not res then
        ngx.log(ngx.ERR, err)
        ngx.say(err)
        return
    else
        if res.body == nil then
            ngx_log(ngx_err, "res.body is nil")
            return
        end
        for i=1, #res.body do
            local host = string.sub(res.body[i],8,-2)
            ngx.say(host)
        end
    end

    return
end

return _M
