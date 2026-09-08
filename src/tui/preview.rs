use super::model::Model;
use crate::backend::regfile;
use crate::oflags::O_NOFOLLOW;
use std::io::Read;
use std::os::unix::fs::MetadataExt;

const TEXT_BYTES:u64=256*1024;
const TEXT_LINES:usize=2000;
pub fn load(m:&mut Model,force:bool) {
    if !force && (!m.preview_visible || !m.preview_auto){return;}
    let Some(path)=m.current_path()else{return;};
    if !force && path==m.preview_path{return;}
    m.preview_path=path.clone();m.preview.clear();
    let Some(row)=m.rows.get(&m.cursor)else{return;};
    m.preview.push(row.name.clone());
    m.preview.push(format!("{} · {}",row.kind,super::render::bytes(row.size)));
    if !row.link.is_empty(){m.preview.push(format!("→ {}",row.link));return;}
    if row.directory {m.preview.push("Folder".into());return;}
    if !row.kind.to_lowercase().contains("text") && !row.kind.to_lowercase().contains("document") && !row.kind.to_lowercase().contains("source") {return;}
    let before=match std::fs::symlink_metadata(&path){Ok(v)=>v,Err(_)=>{m.preview.push("Could not read preview".into());return;}};
    let file=match regfile::open_if_regular(&path,O_NOFOLLOW){Ok(v)=>v,Err(_)=>{m.preview.push("Could not read preview".into());return;}};
    if !file.metadata().is_ok_and(|after|before.dev()==after.dev()&&before.ino()==after.ino()){m.preview.push("Selected item changed".into());return;}
    let mut body=Vec::new();
    if file.take(TEXT_BYTES+1).read_to_end(&mut body).is_err(){m.preview.push("Could not read preview".into());return;}
    let capped=body.len() as u64>TEXT_BYTES;body.truncate(TEXT_BYTES as usize);
    if body.contains(&0){return;}
    let text=String::from_utf8_lossy(&body);
    m.preview.push(String::new());
    m.preview.extend(text.lines().take(TEXT_LINES).map(super::render::clean));
    if capped || text.lines().count()>TEXT_LINES{m.preview.push("Preview truncated · 256 KB or 2,000 lines".into());}
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::{backend::testdir::TestDir,jsondoc::Json,tui::model::Row};
    #[test] fn text_preview_neutralizes_controls_and_refuses_symlink() {
        let d=TestDir::new("tui-preview");d.file("note.txt","hello\x1b[31m\n\u{202e}world");
        let mut m=Model::new(d.path().into(),&Json::Null);
        m.rows.insert(0,Row{name:"note.txt".into(),directory:false,size:20,mode:0o100644,link:String::new(),kind:"Plain text document".into()});
        load(&mut m,true);
        assert!(!m.preview.join("\n").contains('\x1b'));assert!(!m.preview.join("\n").contains('\u{202e}'));
        std::os::unix::fs::symlink(d.join("note.txt"),d.join("link")).unwrap();
        m.rows.get_mut(&0).unwrap().name="link".into();load(&mut m,true);
        assert!(m.preview.iter().any(|s|s=="Could not read preview"));
    }
}
