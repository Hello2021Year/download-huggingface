# download-huggingface
download
LOG=/mnt_upfs/logs/deepseek-download/flash.$(date +%F_%H%M%S).log
nohup bash ./download_flash.sh > "$LOG" 2>&1 &
echo $! > /mnt_upfs/logs/deepseek-download/flash.pid
echo "$LOG"
