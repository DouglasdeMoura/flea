mod actions;
mod input;
mod keymap;
mod model;
mod preview;
mod render;
mod terminal;
mod theme;
mod wire;

use std::io;
use std::path::PathBuf;
extern "C" { fn setlocale(category:i32,locale:*const std::ffi::c_char)->*mut std::ffi::c_char; }

pub fn run(path:Option<&str>,select:Option<&str>)->i32 {
    let result=(||->io::Result<()>{
        // LC_CTYPE makes wcwidth use the terminal's inherited locale without changing numeric formatting.
        unsafe{setlocale(0,c"".as_ptr());}
        let store=crate::uistore::Store::user().map_err(io::Error::other)?;
        store.settle().map_err(io::Error::other)?;
        let settings=store.read();
        let path=path.map(PathBuf::from).unwrap_or(std::env::current_dir()?);
        let path=if path.is_absolute(){path}else{std::env::current_dir()?.join(path)};
        let mut wire=wire::Wire::start()?;
        let terminal=terminal::Terminal::enter()?;
        let mut model=model::Model::new(path.clone(),&settings);
        let map=keymap::Map::load();let theme=theme::Theme::load();let mut decoder=input::Decoder::default();
        let mut size=terminal::size();model.height=size.1.saturating_sub(2).max(1);model.open(path,&mut wire)?;
        let mut wanted=select.map(str::to_owned);
        while !model.quit&&!terminal.stopped(){
            while let Ok(event)=wire.events.try_recv(){match event{Ok(value)=>model.receive(value,&mut wire)?,Err(e)=>{model.error=e;model.quit=true;}}}
            if let Some(path)=&wanted{if let Some((&index,_))=model.rows.iter().find(|(_,row)|model.row_path(row).to_string_lossy()==path.as_str()){model.cursor=index;wanted=None;}}
            preview::load(&mut model,false);
            render::draw(&model,&theme,&map,size.0,size.1)?;
            let bytes=terminal.read()?;
            for key in decoder.feed(&bytes,bytes.is_empty()){actions::key(&mut model,&key,&map,&mut wire)?;}
            let next=terminal::size();if next!=size{size=next;model.height=size.1.saturating_sub(2).max(1);model.window(&mut wire)?;}
        }
        Ok(())
    })();
    match result{Ok(())=>0,Err(e)=>{eprintln!("flea: terminal interface: {}",e);2}}
}
