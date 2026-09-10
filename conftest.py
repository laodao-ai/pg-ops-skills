# 根 conftest：暂无共用 fixture——每个测试模块自带 subprocess / tmp_path 辅助。
# 这个文件的存在是为了让 pytest.ini 的 testpaths 相对同一个 rootdir 解析，
# 并让 tests/ 作为普通目录可导入（无需 __init__.py）。
