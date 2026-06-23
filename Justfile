# 格式化
fmt:
	shfmt -i 2 -w script/allinone.sh

# 静态检查
check:
	shellcheck -x -e SC2059 script/allinone.sh
