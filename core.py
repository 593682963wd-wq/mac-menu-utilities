"""作者：Wangyuan；日期：2026-10-29；职责：无界面计时预览；原生应用仅人工启动。"""
from datetime import datetime,timedelta

def run(payload):
    if not isinstance(payload,dict):raise TypeError('输入须对象')
    now=datetime.fromisoformat(payload['now']);target=datetime.fromisoformat(payload['target']);interval=int(payload.get('reminder_minutes',30))
    if interval<=0:raise ValueError('提醒间隔须为正')
    return {'remaining_seconds':max(0,int((target-now).total_seconds())),'next_reminder':(now+timedelta(minutes=interval)).isoformat(),'native_apps':['StandReminder','NoSleep','LunchCountdown','ProxyToggle'],'notice':'此命令仅预览，不启动UI、提醒、睡眠抑制或代理切换。'}
