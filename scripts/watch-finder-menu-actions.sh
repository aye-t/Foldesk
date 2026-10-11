#!/bin/zsh
# 实时监视 Foldesk 右键动作。
#
# 用法：先在终端运行本脚本，再去 Finder 里点一次右键菜单，然后回来看输出。
#
#   action received type=docx      → 点击到达了 Foldesk
#   created type=docx at=<路径>     → 文件建成功，路径就是它实际落盘的位置
#   failed type=docx error=…       → 到达了 Foldesk 但失败，原因写在 error 里
#   （什么都没打印）                → 点的是别的软件的菜单项（例如 WPS 自己的「新建」）
#
# Ctrl-C 结束。
set -uo pipefail

echo "正在监视 Foldesk 右键动作（Ctrl-C 结束）"
echo "========================================"
echo "现在去 Finder 里：右键 → 新建文件 → 选一个类型，然后回来看这里。"
echo

exec /usr/bin/log stream \
    --predicate 'subsystem == "com.foldesk.mac.findersync"' \
    --style compact \
    --level info
