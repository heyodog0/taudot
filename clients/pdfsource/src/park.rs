//! A pdfLaTeX parked past its preamble (libtau from `clients/universal`, stock engine): the preamble is typeset once,
//! the engine forks a snapshot just before the line that inputs the batch, and every batch resumes that snapshot in
//! a fresh child. A try then costs its own pages, not process start, format load and preamble (~0.2 s each).
//!
//! The engine is unmodified pdfTeX; libtau serves the project from memory and forks at line reads
//! (docs/universal.md). The result is what a plain run of `preamble + batch` gives (checked by `stock_check`).

use std::fs::File;
use std::io::{BufRead, BufReader};
use std::os::fd::{AsRawFd, FromRawFd};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

pub struct Parked {
    child: Child,
    msgs: BufReader<File>,
    _life: File,
    snap: i32,
    proj: PathBuf,
    out: PathBuf,
    seq: u32,
    /// The preamble this engine holds.
    pub pre: String,
    /// Time to start it and reach the snapshot, ms.
    pub ms_start: f64,
}

pub fn libtau() -> Option<PathBuf> {
    if std::env::var("PDFSOURCE_PARK").is_ok_and(|v| v == "0") {
        return None;
    }
    let p = std::env::var("PDFSOURCE_LIBTAU").map(PathBuf::from).unwrap_or_else(|_| crate::texmf::ref_dir().join("universal/bin-pdfprove/libtau.dylib"));
    p.exists().then_some(p)
}

fn pipe() -> std::io::Result<(File, File)> {
    let mut fds = [0i32; 2];
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(unsafe { (File::from_raw_fd(fds[0]), File::from_raw_fd(fds[1])) })
}

fn cloexec(f: &File, on: bool) {
    unsafe {
        let fl = libc::fcntl(f.as_raw_fd(), libc::F_GETFD);
        libc::fcntl(f.as_raw_fd(), libc::F_SETFD, if on { fl | libc::FD_CLOEXEC } else { fl & !libc::FD_CLOEXEC });
    }
}

/// The main file: the preamble, a clock mark, the batch's input line (the snapshot is taken as TeX reads it), a mark, the end.
const INPUT_LINE: &str = "\\csname @@input\\endcsname pbody \n";

impl Parked {
    pub fn start(dir: &Path, pdflatex: &Path, env: &[(String, String)], pre: &str) -> std::io::Result<Parked> {
        let t = Instant::now();
        let _ = std::fs::remove_dir_all(dir);
        let proj = dir.join("proj");
        let out = dir.join("out");
        std::fs::create_dir_all(&proj)?;
        std::fs::create_dir_all(&out)?;
        // pbody.tex is opened once here so that libtau holds it: a resumed child reloads the files it holds from disk
        // as it forks (before saying R), so the next chunk may be written while it runs.
        let head = format!("{pre}\\immediate\\write-1{{PSTIME \\the\\pdfelapsedtime}}\\openin15=pbody.tex \\closein15\n");
        let main = format!("{head}{INPUT_LINE}\\immediate\\write-1{{PSTIME \\the\\pdfelapsedtime}}\\PSend\n");
        std::fs::write(proj.join("main.tex"), main)?;
        std::fs::write(proj.join("pbody.tex"), "\n")?;
        let (msg_r, msg_w) = pipe()?;
        let (life_r, life_w) = pipe()?;
        cloexec(&msg_r, true);
        cloexec(&life_w, true);
        cloexec(&msg_w, false);
        cloexec(&life_r, false);
        let child = Command::new(pdflatex)
            .args(["-interaction=batchmode", "main.tex"])
            .current_dir(&proj)
            .envs(env.iter().cloned())
            .env("DYLD_INSERT_LIBRARIES", libtau().unwrap())
            .env("TAU_PROJECT", &proj)
            .env("TAU_OUT", &out)
            .env("TAU_FD", msg_w.as_raw_fd().to_string())
            .env("TAU_LIFE", life_r.as_raw_fd().to_string())
            .env("TAU_SNAPSHOT_MS", "1000000000")
            .env("TAU_MARK", format!("main.tex {} {}", head.len(), head.len() + 1))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?;
        drop(msg_w);
        drop(life_r);
        let mut p = Parked { child, msgs: BufReader::new(msg_r), _life: life_w, snap: 0, proj, out, seq: 0, pre: pre.to_string(), ms_start: 0.0 };
        // S: the snapshot (the engine itself parks); E: the first runner (an empty batch) ends. Either order.
        let me = p.child.id().to_string();
        let mut ended = false;
        while p.snap == 0 || !ended {
            let l = p.next_msg(Duration::from_secs(120))?;
            let f: Vec<&str> = l.split_whitespace().collect();
            match f.first().copied() {
                Some("S") => p.snap = f[1].parse().unwrap_or(0),
                Some("E") if f[1] == me => return Err(std::io::Error::other("engine ended before the batch line (preamble error?)")),
                Some("E") => {
                    let _ = std::fs::remove_dir_all(p.out.join(format!("{}-0-{}", f[5], f[1])));
                    ended = true;
                }
                _ => {}
            }
        }
        p.ms_start = t.elapsed().as_secs_f64() * 1000.0;
        Ok(p)
    }

    fn next_msg(&mut self, timeout: Duration) -> std::io::Result<String> {
        let mut pfd = libc::pollfd { fd: self.msgs.get_ref().as_raw_fd(), events: libc::POLLIN, revents: 0 };
        if self.msgs.buffer().is_empty() {
            let n = unsafe { libc::poll(&mut pfd, 1, timeout.as_millis() as i32) };
            if n <= 0 {
                return Err(std::io::Error::other("engine: no message (timeout)"));
            }
        }
        let mut l = String::new();
        if self.msgs.read_line(&mut l)? == 0 {
            return Err(std::io::Error::other("engine: pipe closed"));
        }
        Ok(l)
    }

    /// Typeset several batches at once, each in its own child of the snapshot; their output folders, in order.
    pub fn run_many(&mut self, bodies: &[String]) -> std::io::Result<Vec<PathBuf>> {
        if bodies.len() == 1 {
            return Ok(vec![self.run(&bodies[0])?]);
        }
        let first = self.seq + 1;
        let mut runners: Vec<i32> = vec![];
        let mut done: std::collections::HashMap<u32, PathBuf> = Default::default();
        let mut fail = |p: &mut Parked, runners: &[i32], e: std::io::Error| {
            for &r in runners {
                unsafe { libc::kill(r, libc::SIGKILL) };
            }
            let _ = p;
            e
        };
        for body in bodies {
            self.seq += 1;
            let seq = self.seq;
            std::fs::write(self.proj.join("pbody.tex"), body)?;
            std::fs::write(self.out.join(format!("ctl-{}", self.snap)), format!("seq {seq}\ngo {seq}\n"))?;
            unsafe { libc::kill(self.snap, libc::SIGUSR1) };
            // The runner reads the project files right after the fork, then says R: only then may pbody.tex change.
            loop {
                let l = match self.next_msg(Duration::from_secs(60)) {
                    Ok(l) => l,
                    Err(e) => return Err(fail(self, &runners, e)),
                };
                let f: Vec<&str> = l.split_whitespace().collect();
                match f.first().copied() {
                    Some("R") if f.get(3) == Some(&seq.to_string().as_str()) => {
                        runners.push(f[2].parse().unwrap_or(0));
                        break;
                    }
                    Some("E") => {
                        let s: u32 = f[2].parse().unwrap_or(0);
                        done.insert(s, self.out.join(format!("{}-{s}-{}", f[5], f[1])));
                    }
                    Some("X") => return Err(fail(self, &runners, std::io::Error::other(format!("engine: runner crashed ({})", l.trim())))),
                    _ => {}
                }
            }
        }
        while (first..=self.seq).any(|s| !done.contains_key(&s)) {
            let l = match self.next_msg(Duration::from_secs(600)) {
                Ok(l) => l,
                Err(e) => return Err(fail(self, &runners, e)),
            };
            let f: Vec<&str> = l.split_whitespace().collect();
            match f.first().copied() {
                Some("E") => {
                    let s: u32 = f[2].parse().unwrap_or(0);
                    done.insert(s, self.out.join(format!("{}-{s}-{}", f[5], f[1])));
                }
                Some("X") => return Err(fail(self, &runners, std::io::Error::other(format!("engine: runner crashed ({})", l.trim())))),
                _ => {}
            }
        }
        Ok((first..=self.seq).map(|s| done.remove(&s).unwrap()).collect())
    }

    /// Typeset one batch from the snapshot; returns the output folder (main.pdf, main.log), which the caller removes.
    pub fn run(&mut self, body: &str) -> std::io::Result<PathBuf> {
        self.seq += 1;
        let seq = self.seq;
        std::fs::write(self.proj.join("pbody.tex"), body)?;
        std::fs::write(self.out.join(format!("ctl-{}", self.snap)), format!("seq {seq}\ngo {seq}\n"))?;
        unsafe { libc::kill(self.snap, libc::SIGUSR1) };
        let mut runner = 0;
        loop {
            let l = match self.next_msg(Duration::from_secs(600)) {
                Ok(l) => l,
                Err(e) => {
                    if runner > 0 {
                        unsafe { libc::kill(runner, libc::SIGKILL) };
                    }
                    return Err(e);
                }
            };
            let f: Vec<&str> = l.split_whitespace().collect();
            match f.first().copied() {
                Some("R") if f.get(3) == Some(&seq.to_string().as_str()) => runner = f[2].parse().unwrap_or(0),
                Some("E") if f.get(2) == Some(&seq.to_string().as_str()) => {
                    return Ok(self.out.join(format!("{}-{seq}-{}", f[5], f[1])));
                }
                Some("X") if f.get(2) == Some(&runner.to_string().as_str()) => {
                    return Err(std::io::Error::other(format!("engine: runner crashed ({})", l.trim())));
                }
                _ => {}
            }
        }
    }
}

impl Drop for Parked {
    fn drop(&mut self) {
        // Closing the lifeline ends the parked engine; make sure.
        if self.snap > 0 {
            unsafe { libc::kill(self.snap, libc::SIGKILL) };
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(self.proj.parent().unwrap());
    }
}
