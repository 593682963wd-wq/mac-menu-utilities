# macOS菜单栏实用工具源码

保留休息提醒、防休眠、午饭倒计时、代理切换四个独立Swift源文件；去除个人命名。附无界面计时预览。

## 使用

Python 3.11+。在本目录建立独立虚拟环境：

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python cli.py example.json
.venv/bin/python -m unittest discover -v
```

`example.json`从零编写，仅含虚构输入。可以显式提供自己的同结构JSON文件。输出默认为终端；`--output result.json`使用独占创建，避免覆盖已有结果。CLI失败退出码2。

## 数据与边界

不发现本机账号、不读取环境中的模型密钥、不发送消息、不请求远端数据。只处理调用方明确传入的文件、记录或参数。合成示例不代表任何实际业务结果。原生源码需macOS+Swift工具链；此次只编译，不实际启动窗口、申请通知、播放声音、修改代理或休眠状态。代理工具需用户自行配置本地服务，未保留当前配置。

## 发布状态

本项目源码采用 MIT 许可证，见 LICENSE。依赖按各自上游许可使用，安装的依赖/模型/字体/媒体不随此源码目录分发。

原生编译：`swiftc native/StandReminder.swift -o stand-reminder`，其余三个同理。编译产物由使用者自行决定是否启动。

ProxyToggle仅接受 `--config /absolute/path/verge.yaml` 或 `PROXY_CONFIG_PATH`；未配置立即退出，不读取用户设置、不创建菜单或申请辅助功能。可选 `PROXY_LOG_PATH` 显式开启日志。原生组件仅编译，未启动菜单栏/系统代理。

## 2026-11-08 协作修订

- NoSleep日志和PID位于仅当前所有者可访问的临时目录，并拒绝日志符号链接。
- 重复实例退出不会停止另一实例的caffeinate。
- 代理布尔配置只解析实际值，配置内容改变时重载快捷键设置。
- 仅typecheck和纯逻辑回归，未启动菜单栏程序、改变代理或发起系统权限请求。

集合根目录 `verify_release.py --project personal-macos-utilities` 可复跑合成测试和首次使用示例；本轮以集合验证报告为准。

The break timer accepts `BREAK_TIMES` as a comma-separated list of local HH:MM times, for example `10:00,15:00`. The countdown accepts `LUNCH_AT` and `WORK_END_AT` in HH:MM format. With missing or invalid settings, the tools use their demonstration times (breaks at 10:00 and 15:00, lunch at 12:00, end of day at 18:00).
