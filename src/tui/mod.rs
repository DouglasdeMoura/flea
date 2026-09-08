mod actions;
mod completion;
mod empty;
mod editor;
mod graphics;
mod input;
mod job;
mod keymap;
mod media;
mod model;
mod pdf;
mod preview;
mod render;
mod terminal;
mod taildrop;
mod theme;
mod wire;

use std::io;
use std::path::PathBuf;
extern "C" {
    fn setlocale(category: i32, locale: *const std::ffi::c_char) -> *mut std::ffi::c_char;
}

pub fn run(path: Option<&str>, select: Option<&str>) -> i32 {
    let result = (|| -> io::Result<()> {
        // LC_CTYPE makes wcwidth use the terminal's inherited locale without changing numeric formatting.
        unsafe {
            setlocale(0, c"".as_ptr());
        }
        let store = crate::uistore::Store::user().map_err(io::Error::other)?;
        store.settle().map_err(io::Error::other)?;
        let settings = store.read();
        let path = path.map(PathBuf::from).unwrap_or(std::env::current_dir()?);
        let path = if path.is_absolute() {
            path
        } else {
            std::env::current_dir()?.join(path)
        };
        let mut wire = wire::Wire::start()?;
        let terminal = terminal::Terminal::enter()?;
        let mut model = model::Model::new(path.clone(), &settings);
        let map = keymap::Map::load();
        let theme = theme::Theme::load();
        let mut decoder = input::Decoder::default();
        let mut size = terminal::size();
        model.height = size.1.saturating_sub(2).max(1);
        model.columns = size.0;
        model.restore_path = select.map(PathBuf::from);
        model.open(path, &mut wire)?;
        let started = std::time::Instant::now();
        let mut frame = String::new();
        let mut graphics = graphics::Graphics::new();
        let mut thumbnail = PathBuf::new();
        let mut preview_generation = 0;
        let mut last_message = String::new();
        let mut message_at = std::time::Instant::now();
        while !model.quit && !terminal.stopped() {
            while let Ok(event) = wire.events.try_recv() {
                match event {
                    Ok(value) => model.receive(value, &mut wire)?,
                    Err(e) => return Err(io::Error::other(e)),
                }
            }
            preview::load(&mut model, false);
            preview::request(&mut model, &mut wire)?;
            preview::layout(&mut model);
            model.taildrop.poll();
            if let Some(result) = model.taildrop.sent.take() {
                match result { Ok(message) => model.message = message, Err(error) => model.error = error }
            }
            if let Some(completion) = model.completer.poll() { model.completion = completion; }
            if model.message != last_message {
                last_message = model.message.clone();
                message_at = std::time::Instant::now();
            }
            // Match StatusBar.messageMs while keeping the actionable undo receipt until dismissed.
            const MESSAGE_TIME: std::time::Duration = std::time::Duration::from_millis(4000);
            if !model.message.contains("Undo available") && message_at.elapsed() >= MESSAGE_TIME { model.message.clear(); }
            let visible = (model.preview_visible || model.quicklook) && model.selected.len() < 2;
            let overlay = model.menu || model.sheet || model.editor.is_some();
            let current = model.current_path();
            let preview_allowed = model.preview_loaded
                && current.as_ref() == Some(&model.preview_path);
            let reserved = 7 + model.preview_metadata.len().min(3);
            let geometry = if model.quicklook {
                (size.0.saturating_sub(2), size.1.saturating_sub(reserved), 2, 4)
            } else {
                (
                    size.0
                        .saturating_sub(size.0 * 22 / 100 + size.0 * 40 / 100 + 2),
                    size.1.saturating_sub(reserved),
                    size.0 * 22 / 100 + size.0 * 40 / 100 + 3,
                    4,
                )
            };
            let pixels = terminal::cell_pixels()
                .map(|cell| (geometry.0 * cell.0, geometry.1 * cell.1))
                .filter(|pixels| pixels.0 > 0 && pixels.1 > 0);
            let graphics_ready = pixels.is_some() || graphics.protocol == graphics::Protocol::None;
            let pixel_extent = pixels.unwrap_or((0, 0));
            let kind = model
                .rows
                .get(&model.cursor)
                .map(|r| r.icon.to_lowercase())
                .unwrap_or_default();
            let is_media = kind.contains("audio") || kind.contains("video");
            let is_pdf = kind.contains("pdf");
            if !visible
                || !preview_allowed
                || !is_media
                || overlay
                || model.player.as_ref().is_some_and(|p| {
                    Some(&p.path) != current.as_ref()
                        || p.geometry != geometry
                        || p.pixels != pixel_extent
                })
            {
                if let Some(player) = model.player.take() {
                    model.playback = Some((player.path.clone(), player.position, player.paused));
                }
            }
            if !visible
                || !preview_allowed
                || !graphics_ready
                || !is_pdf
                || model
                    .pdf
                    .as_ref()
                    .is_some_and(|p| Some(&p.path) != current.as_ref())
            {
                model.pdf = None;
            }
            if visible && preview_allowed {
                if let Some(path) = current.clone() {
                    if is_media && !overlay && model.player.is_none() && graphics_ready
                        && model.preview_failed.as_ref() != Some(&path)
                    {
                        match media::Player::start(
                            &path,
                            graphics.protocol,
                            geometry,
                            size,
                            pixel_extent,
                        ) {
                            Ok(mut player) => {
                                if let Some((previous, position, paused)) = &model.playback {
                                    if previous == &path {
                                        player.resume = Some((*position, *paused));
                                    }
                                }
                                model.player = Some(player);
                            }
                            Err(e) => {
                                model.error = format!("Media preview: {}", e);
                                model.preview_failed = Some(path.clone());
                            }
                        }
                    }
                    if is_pdf && model.pdf.is_none() && graphics_ready {
                        model.pdf = Some(pdf::Pdf::new(
                            path.clone(),
                            graphics.protocol,
                            geometry.0,
                            geometry.1,
                            pixel_extent,
                        ));
                    }
                    if path != thumbnail || preview_generation != model.preview_generation {
                        if let Some(index) = model.thumb_index {
                            wire.send(vec![
                                ("c", wire::word("thumbcancel")),
                                ("rows", crate::jsondoc::Json::Arr(vec![wire::number(index)])),
                            ])?;
                        }
                        graphics.clear();
                        model.image_file = None;
                        model.thumb_index = None;
                        thumbnail = path;
                        preview_generation = model.preview_generation;
                        if !is_media
                            && !is_pdf
                            && model.rows.get(&model.cursor).is_some_and(|r| r.thumbnail)
                        {
                            if kind.starts_with("image") {
                                model.image_file = Some(thumbnail.clone());
                            } else {
                                model.thumb_index = Some(model.cursor);
                                wire.send(vec![
                                ("c", wire::word("thumb")),
                                (
                                    "rows",
                                    crate::jsondoc::Json::Arr(vec![wire::number(model.cursor)]),
                                ),
                                ])?;
                            }
                        }
                    }
                }
            } else {
                if let Some(index) = model.thumb_index.take() {
                    wire.send(vec![("c", wire::word("thumbcancel")), ("rows", crate::jsondoc::Json::Arr(vec![wire::number(index)]))])?;
                }
                graphics.clear();
                model.image_file = None;
                thumbnail = PathBuf::new();
            }
            if let (Some(path), Some(pixels)) = (&model.image_file, pixels) {
                graphics.request(path.clone(), geometry.0, geometry.1, pixels);
            }
            if visible && !graphics_ready && (is_media || is_pdf || model.image_file.is_some()) {
                model.error =
                    "Inline preview unavailable: terminal did not report pixel dimensions".into();
            }
            if graphics.accept() {
                frame.clear();
            }
            if !graphics.error.is_empty() {
                model.error = format!("Image preview: {}", std::mem::take(&mut graphics.error));
            }
            if let Some(player) = &mut model.player {
                player.poll();
                if !player.error.is_empty() {
                    model.error = player.error.clone();
                    model.preview_failed = Some(player.path.clone());
                }
            }
            if model.player.as_ref().is_some_and(|p| !p.error.is_empty()) {
                model.player = None;
            }
            if let Some(pdf) = &mut model.pdf {
                if (pdf.columns, pdf.rows) != (geometry.0, geometry.1) || pdf.pixels != pixel_extent
                {
                    pdf.columns = geometry.0;
                    pdf.rows = geometry.1;
                    pdf.pixels = pixel_extent;
                    pdf.refresh();
                }
                if pdf.poll() {
                    frame.clear();
                }
                if !pdf.error.is_empty() {
                    model.error = std::mem::take(&mut pdf.error);
                }
            }
            let changed = render::draw(
                &model,
                &theme,
                &map,
                size.0,
                size.1,
                started.elapsed(),
                &mut frame,
            )?;
            let image = model
                .pdf
                .as_ref()
                .map(|p| p.bytes.as_slice())
                .unwrap_or(&graphics.bytes);
            if changed && graphics.protocol == graphics::Protocol::Kitty {
                print!("\x1b_Ga=d,d=I,i=42,q=2\x1b\\");
                std::io::Write::flush(&mut std::io::stdout())?;
            }
            if changed && !image.is_empty() && !overlay {
                use std::io::Write;
                print!("\x1b[s\x1b[{};{}H", geometry.3, geometry.2);
                std::io::stdout().write_all(image)?;
                print!("\x1b[u");
                std::io::stdout().flush()?;
            }
            let bytes = terminal.read()?;
            for key in decoder.feed(&bytes, bytes.is_empty()) {
                if let Err(e) = actions::key(&mut model, &key, &map, &mut wire) {
                    model.error = e.to_string();
                }
            }
            if decoder.sixel && graphics.protocol == graphics::Protocol::None {
                graphics.protocol = graphics::Protocol::Sixel;
                thumbnail = PathBuf::new();
            }
            let next = terminal::size();
            if next != size {
                size = next;
                model.height = size.1.saturating_sub(2).max(1);
                model.columns = size.0;
                model.window(&mut wire)?;
            }
        }
        Ok(())
    })();
    match result {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("flea: terminal interface: {}", e);
            2
        }
    }
}
