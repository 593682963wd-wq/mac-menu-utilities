"""Native logic is compiled without app.run; UI rendering and dispatch stay disabled."""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

class ApiRegressions(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory();cls.addClassCleanup(cls.temp.cleanup)
        cls.root=Path(cls.temp.name)
        cls.swift=shutil.which('swiftc')
        if not cls.swift:raise unittest.SkipTest('Swift compiler unavailable; native behavior requires macOS')
        for name in ('NoSleep','ProxyToggle'):
            source=(Path('native')/(name+'.swift')).read_text(encoding='utf-8')
            source=source.split('\nlet app = NSApplication.shared')[0]
            if name=='NoSleep':
                source=re.sub(r'^private let runtimeDirectoryURL = .*$', 'private let runtimeDirectoryURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)',source,flags=re.M)
                source=re.sub(r'^private let pidFileURL = .*$', 'private let pidFileURL = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("caffeinate.pid")',source,flags=re.M)
                source=re.sub(r'^private let logFileURL = .*$', 'private let logFileURL = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("activity.log")',source,flags=re.M)
                source+=r'''
let testRoot = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let mode = CommandLine.arguments[1]
if mode == "log" {
    let target = testRoot.appendingPathComponent("target.json")
    try "{\"synthetic\":true}".write(to: target, atomically: false, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: logFileURL, withDestinationURL: target)
    appendLog("synthetic regression")
    let contents = try String(contentsOf: target, encoding: .utf8)
    if contents != "{\"synthetic\":true}" { exit(3) }
} else if mode == "duplicate-exit" {
    try "999999\n".write(to: pidFileURL, atomically: false, encoding: .utf8)
    let delegate = AppDelegate()
    delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    if !FileManager.default.fileExists(atPath: pidFileURL.path) { exit(3) }
}
print("native regression passed")
'''
            else:
                # Rendering creates status bar resources; neutralize only that UI method.
                start=source.index('    func render() {');end=source.index('    private func drawPill(',start)
                source=source[:start]+'    func render() {}\n\n'+source[end:]
                poll=re.search(r'pollTimer = Timer.scheduledTimer\(withTimeInterval: 1.0, repeats: true\) \{ \[weak self\] _ in(.*?)\n        \}',source,re.S)
                if not poll:raise AssertionError('poll timer callback missing')
                body=poll[1].replace('self?.','delegate.')
                source+='\nfunc pollTick(_ delegate: AppDelegate) {'+body+'\n}\n'
                source+=r'''
let delegate = AppDelegate()
let mode = CommandLine.arguments[1]
if mode == "bool" {
    try "enable_system_proxy: false # true means enabled\nenable_tun_mode: false # true means enabled\n".write(toFile: kVergeYaml, atomically: false, encoding: .utf8)
    delegate.readState()
    if delegate.sysProxy || delegate.tun { exit(3) }
} else if mode == "hotkey" {
    try "hotkeys:\n  - toggle_system_proxy,Ctrl+Shift+A\n".write(toFile: kVergeYaml, atomically: false, encoding: .utf8)
    delegate.loadHotkeys()
    if delegate.vpnHotkey?.raw != "Ctrl+Shift+A" { exit(4) }
    try "hotkeys:\n  - toggle_system_proxy,Ctrl+Shift+B\n".write(toFile: kVergeYaml, atomically: false, encoding: .utf8)
    pollTick(delegate)
    if delegate.vpnHotkey?.raw != "Ctrl+Shift+B" { exit(3) }
}
print("native regression passed")
'''
            path=cls.root/(name+'.swift');path.write_text(source,encoding='utf-8')
            command=[cls.swift,'-module-cache-path',str(cls.root/'module-cache'),str(path),'-o',str(cls.root/name)]
            result=subprocess.run(command,capture_output=True,text=True,timeout=90)
            if result.returncode:raise AssertionError(result.stdout+result.stderr)
    def execute(self,binary,mode):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp);path.chmod(0o700)
            env={**os.environ,'PROXY_CONFIG_PATH':str(path/'verge.yaml')}
            result=subprocess.run([str(self.root/binary),mode,str(path)],capture_output=True,text=True,env=env,timeout=10)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
    def test_log_symlink_does_not_modify_target(self):self.execute('NoSleep','log')
    def test_rejected_instance_exit_preserves_shared_pid(self):self.execute('NoSleep','duplicate-exit')
    def test_yaml_boolean_ignores_comment_true(self):self.execute('ProxyToggle','bool')
    def test_poll_refreshes_in_place_hotkey_change(self):self.execute('ProxyToggle','hotkey')
