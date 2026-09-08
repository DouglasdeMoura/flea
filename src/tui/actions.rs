use super::{input::Key,keymap::Map,model::{Model,Tab},wire::{word,Wire}};
use crate::jsondoc::Json;
use std::{io,path::PathBuf};

pub fn key(model:&mut Model,key:&Key,map:&Map,wire:&mut Wire)->io::Result<()> {
    if model.editor.is_some(){return edit(model,key,wire);}
    if model.sheet { if key.name=="Escape" || key.text=="?"{model.sheet=false;} return Ok(()); }
    if model.menu {
        match key.name.as_str(){"Escape"=>model.menu=false,"Down"=>model.menu_cursor=(model.menu_cursor+1)%2,"Up"=>model.menu_cursor=(model.menu_cursor+1)%2,"Return"=>{model.menu=false;return act(model,if model.menu_cursor==0{"open"}else{"toggleHidden"},wire);},_=>{if key.text=="j"||key.text=="k"{model.menu_cursor=(model.menu_cursor+1)%2;}}}
        return Ok(());
    }
    if model.preview_focus || model.quicklook {
        if key.name=="Escape" || (key.name=="Tab" && key.mods=="ctrl") {model.preview_focus=false;model.quicklook=false;}
        return Ok(());
    }
    if key.mods.is_empty() && key.text.len()==1 {
        if let Ok(n)=key.text.parse::<usize>() { if (1..=9).contains(&n) { return tab(model,n-1,wire); } }
    }
    if key.name=="PageDown" && key.mods=="ctrl" {return tab(model,(model.tab+1)%model.tabs.len(),wire);}
    if key.name=="PageUp" && key.mods=="ctrl" {return tab(model,(model.tab+model.tabs.len()-1)%model.tabs.len(),wire);}
    if key.name=="Tab" && key.mods=="ctrl" {model.preview_focus=model.preview_visible;return Ok(());}
    if key.name=="P" && key.mods=="alt" {model.preview_visible=!model.preview_visible;return Ok(());}
    if key.name=="Space" && key.mods=="ctrl" {model.preview_path=PathBuf::new();super::preview::load(model,true);return Ok(());}
    let action=map.action(key,&model.preset);
    if action.is_empty(){
        match key.text.as_str(){"q"=>model.quit=true,"H"=>history(model,false,wire)?,"L"=>history(model,true,wire)?,_=>{}}
        return Ok(());
    }
    act(model,&action,wire)
}
fn act(m:&mut Model,action:&str,w:&mut Wire)->io::Result<()> {
    if m.pending.is_some() && !matches!(action,"quit"|"escape"|"keymapSheet"){return Ok(());}
    match action {
        "cursorDown"=>m.move_by(1,false,w)?,"cursorUp"=>m.move_by(-1,false,w)?,
        "extendDown"=>m.move_by(1,true,w)?,"extendUp"=>m.move_by(-1,true,w)?,
        "pageDown"=>m.move_by(m.height as isize,false,w)?,"pageUp"=>m.move_by(-(m.height as isize),false,w)?,
        "first"|"cursorFirst"=>{m.cursor=0;m.window(w)?;},"last"|"cursorLast"=>{m.cursor=m.total.saturating_sub(1);m.window(w)?;},
        "parent"=>{if let Some(p)=m.path.parent().map(|p|p.to_path_buf()){navigate(m,p,w)?;}},
        "historyBack"=>history(m,false,w)?,"historyForward"=>history(m,true,w)?,
        "open"=>{if let Some(path)=m.current_path(){if m.rows.get(&m.cursor).is_some_and(|r|r.directory){navigate(m,path,w)?;}else if crate::open::open(&path.to_string_lossy())!=0{m.error="Could not open selected file".into();}}},
        "toggleSelect"=>{if m.rows.contains_key(&m.cursor)&&!m.selected.remove(&m.cursor){m.selected.insert(m.cursor);}},
        "selectAll"=>{m.selected=(0..m.total).collect();},
        "toggleHidden"=>{m.hidden=!m.hidden;save("hidden",Json::Bool(m.hidden),m);m.open(m.path.clone(),w)?;},
        "pathBar"=>m.editor=Some(("path".into(),m.path.to_string_lossy().into_owned())),
        "search"=>m.editor=Some(("search".into(),String::new())),
        "rename"=>{if m.selected.len()>1{m.error="Select one item to rename".into();}else if let Some(row)=m.rows.get(&m.cursor){m.editor=Some(("rename".into(),row.name.clone()));}},
        "newFolder"=>m.editor=Some(("mkdir".into(),"New Folder".into())),
        "copy"|"cut"=>{m.cut=action=="cut";m.pending_clipboard=true;w.send(vec![("c",word("paths")),("rows",m.indices())])?;},
        "paste"=>{if m.clipboard.is_empty(){m.message="Nothing to paste".into();}else{w.send(vec![("c",word("transfer")),("op",word(if m.cut{"move"}else{"copy"})),("paths",Json::Arr(m.clipboard.iter().map(|p|word(p)).collect())),("dest",word(&m.path.to_string_lossy()))])?;}},
        "trash"|"trashArm"=>{if m.total>0{w.send(vec![("c",word("trash")),("rows",m.indices())])?;}},
        "undo"=>w.send(vec![("c",word("undo"))])?,
        "sortNext"|"sortReverse"=>{
            if action=="sortReverse"{m.reverse=!m.reverse;}else{m.sort=match m.sort.as_str(){"name"=>"size","size"=>"mtime",_=>"name"}.into();}
            w.send(vec![("c",word("sort")),("by",word(&m.sort)),("desc",Json::Bool(m.reverse))])?;
        },
        "tabNew"=>{m.tabs.push(Tab{path:m.path.clone(),cursor:0,back:Vec::new(),forward:Vec::new()});let index=m.tabs.len()-1;tab(m,index,w)?;},
        "tabClose"=>{if m.tabs.len()==1{m.quit=true;}else{m.tabs.remove(m.tab);m.tab=m.tab.min(m.tabs.len()-1);let p=m.tabs[m.tab].path.clone();m.open(p,w)?;}},
        "preview"=>{m.quicklook=true;super::preview::load(m,true);},
        "menu"=>{m.menu=true;m.menu_cursor=0;},"keymapSheet"=>m.sheet=true,
        "reveal"=>{if !m.search.is_empty(){if let Some(p)=m.current_path().and_then(|p|p.parent().map(|v|v.to_path_buf())){navigate(m,p,w)?;}}},
        "escape"=>{if !m.error.is_empty(){m.error.clear();}else if m.searching{w.send(vec![("c",word("searchcancel"))])?;}else if !m.search.is_empty(){m.open(m.path.clone(),w)?;}else{m.selected.clear();}},
        "quit"=>m.quit=true,
        _=>{}
    }
    Ok(())
}
fn navigate(m:&mut Model,path:PathBuf,w:&mut Wire)->io::Result<()> {m.back.push(m.path.clone());m.forward.clear();m.open(path,w)}
fn history(m:&mut Model,forward:bool,w:&mut Wire)->io::Result<()> {
    let next=if forward{m.forward.pop()}else{m.back.pop()};
    if let Some(path)=next{if forward{m.back.push(m.path.clone());}else{m.forward.push(m.path.clone());}m.open(path,w)?;}
    Ok(())
}
fn tab(m:&mut Model,index:usize,w:&mut Wire)->io::Result<()> {
    if index>=m.tabs.len() || index==m.tab{return Ok(());}
    m.tabs[m.tab]=Tab{path:m.path.clone(),cursor:m.cursor,back:m.back.clone(),forward:m.forward.clone()};
    m.tab=index;let next=m.tabs[index].clone();m.cursor=next.cursor;m.back=next.back;m.forward=next.forward;m.open(next.path,w)
}
fn save(key:&str,value:Json,m:&mut Model){
    if let Err(e)=crate::uistore::Store::user().and_then(|s|s.update(&Json::Obj(vec![(key.into(),value)]))){m.error=format!("Could not save settings: {}",e);}
}
fn edit(m:&mut Model,key:&Key,w:&mut Wire)->io::Result<()> {
    let (kind,mut value)=m.editor.take().unwrap();
    if key.name=="Escape"{return Ok(());}
    if key.name=="Backspace"{value.pop();}
    else if key.name=="Return"{
        match kind.as_str(){
            "path"=>{let expanded=if value=="~"||value.starts_with("~/"){std::env::var("HOME").unwrap_or_default()+&value[1..]}else{value};let p=PathBuf::from(expanded);navigate(m,if p.is_absolute(){p}else{m.path.join(p)},w)?;},
            "search"=>{m.searching=true;m.search="Search: starting".into();w.send(vec![("c",word("search")),("path",word(&m.path.to_string_lossy())),("query",word(&value)),("hidden",Json::Bool(m.hidden))])?;},
            "rename"=>{if let Some(p)=m.current_path(){w.send(vec![("c",word("rename")),("path",word(&p.to_string_lossy())),("to",word(&value))])?;}},
            "mkdir"=>w.send(vec![("c",word("mkdir")),("path",word(&m.path.to_string_lossy())),("name",word(&value))])?,_=>{}
        }
        return Ok(());
    }else if key.mods.is_empty(){value.push_str(&key.text);}
    m.editor=Some((kind,value));Ok(())
}
