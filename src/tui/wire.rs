use crate::jsondoc::{self, Json};
use std::io::{self, BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};

pub struct Wire { child: Child, input: ChildStdin, pub events: Receiver<Result<Json,String>> }
impl Wire {
    pub fn start() -> io::Result<Self> {
        let mut child=Command::new(std::env::current_exe()?).arg("--backend").stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn()?;
        let input=child.stdin.take().ok_or_else(||io::Error::other("backend stdin unavailable"))?;
        let output=child.stdout.take().ok_or_else(||io::Error::other("backend stdout unavailable"))?;
        let (tx,events)=mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(output).lines() {
                let result=line.map_err(|e|e.to_string()).and_then(|line|jsondoc::parse(&line));
                if tx.send(result).is_err() { return; }
            }
            let _=tx.send(Err("The listing backend stopped".into()));
        });
        Ok(Self{child,input,events})
    }
    pub fn send(&mut self, fields: Vec<(&str,Json)>) -> io::Result<()> {
        let document=Json::Obj(fields.into_iter().map(|(k,v)|(k.into(),v)).collect());
        let text=jsondoc::render(&document).replace('\n',"");
        writeln!(self.input,"{}",text)?;
        self.input.flush()
    }
}
impl Drop for Wire {
    fn drop(&mut self) {
        let _=self.send(vec![("c",word("quit"))]);
        // A requested shutdown must not orphan a backend; its own quit drains operation workers.
        let _=self.child.wait();
    }
}
pub fn word(value:&str)->Json { Json::Str(value.into()) }
pub fn number(value:usize)->Json { Json::Num(value.to_string()) }
pub fn text<'a>(value:&'a Json,key:&str)->&'a str { value.get(key).and_then(Json::as_str).unwrap_or("") }
pub fn count(value:&Json,key:&str)->usize { value.get(key).and_then(Json::as_f64).unwrap_or(0.0).max(0.0) as usize }
pub fn flag(value:&Json,key:&str)->bool { value.get(key).and_then(Json::as_bool).unwrap_or(false) }
