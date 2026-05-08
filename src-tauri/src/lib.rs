use tauri::menu::{
    AboutMetadataBuilder, MenuBuilder, MenuItemBuilder, PredefinedMenuItem, SubmenuBuilder,
};
use tauri::{Emitter, Manager};

#[cfg(target_os = "macos")]
use window_vibrancy::{apply_vibrancy, NSVisualEffectMaterial, NSVisualEffectState};

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            let handle = app.handle();

            #[cfg(target_os = "macos")]
            if let Some(window) = app.get_webview_window("main") {
                let _ = apply_vibrancy(
                    &window,
                    NSVisualEffectMaterial::Sidebar,
                    Some(NSVisualEffectState::FollowsWindowActiveState),
                    None,
                );
            }


            let about = PredefinedMenuItem::about(
                handle,
                Some("About Marktext Next"),
                Some(
                    AboutMetadataBuilder::new()
                        .name(Some("Marktext Next (Demo)"))
                        .version(Some(env!("CARGO_PKG_VERSION")))
                        .build(),
                ),
            )?;

            let app_submenu = SubmenuBuilder::new(handle, "Marktext Next")
                .item(&about)
                .separator()
                .item(
                    &MenuItemBuilder::with_id("settings", "Settings…")
                        .accelerator("CmdOrCtrl+,")
                        .build(handle)?,
                )
                .separator()
                .services()
                .separator()
                .hide()
                .hide_others()
                .show_all()
                .separator()
                .quit()
                .build()?;

            let file_submenu = SubmenuBuilder::new(handle, "File")
                .item(
                    &MenuItemBuilder::with_id("new", "New")
                        .accelerator("CmdOrCtrl+N")
                        .build(handle)?,
                )
                .separator()
                .item(
                    &MenuItemBuilder::with_id("open_file", "Open File…")
                        .accelerator("CmdOrCtrl+O")
                        .build(handle)?,
                )
                .item(
                    &MenuItemBuilder::with_id("open_folder", "Open Folder…")
                        .accelerator("CmdOrCtrl+Shift+O")
                        .build(handle)?,
                )
                .separator()
                .item(
                    &MenuItemBuilder::with_id("save", "Save")
                        .accelerator("CmdOrCtrl+S")
                        .build(handle)?,
                )
                .item(
                    &MenuItemBuilder::with_id("save_as", "Save As…")
                        .accelerator("CmdOrCtrl+Shift+S")
                        .build(handle)?,
                )
                .separator()
                .item(&PredefinedMenuItem::close_window(handle, Some("Close"))?)
                .build()?;

            let edit_submenu = SubmenuBuilder::new(handle, "Edit")
                .undo()
                .redo()
                .separator()
                .cut()
                .copy()
                .paste()
                .select_all()
                .separator()
                .item(
                    &MenuItemBuilder::with_id("find", "Find")
                        .accelerator("CmdOrCtrl+F")
                        .build(handle)?,
                )
                .build()?;

            let view_submenu = SubmenuBuilder::new(handle, "View")
                .item(
                    &MenuItemBuilder::with_id("toggle_sidebar", "Toggle Sidebar")
                        .accelerator("CmdOrCtrl+\\")
                        .build(handle)?,
                )
                .separator()
                .fullscreen()
                .build()?;

            let window_submenu = SubmenuBuilder::new(handle, "Window")
                .minimize()
                .maximize()
                .separator()
                .item(&PredefinedMenuItem::close_window(handle, None)?)
                .build()?;

            let menu = MenuBuilder::new(handle)
                .item(&app_submenu)
                .item(&file_submenu)
                .item(&edit_submenu)
                .item(&view_submenu)
                .item(&window_submenu)
                .build()?;

            app.set_menu(menu)?;

            app.on_menu_event(|app, event| {
                let id = event.id().0.as_str();
                match id {
                    "new" | "open_file" | "open_folder" | "save" | "save_as" | "find"
                    | "settings" | "toggle_sidebar" => {
                        if let Some(window) = app.get_webview_window("main") {
                            let _ = window.emit("menu", id);
                        }
                    }
                    _ => {}
                }
            });

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
