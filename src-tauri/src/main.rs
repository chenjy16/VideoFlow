// macOS 下不需要额外的 windows 子系统配置
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    videoflow_lib::run()
}
