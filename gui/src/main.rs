//! zapret-arch GUI: a thin client over the installed Bash tool and its root
//! helper. Reads state from files and `systemctl`; every mutation goes through
//! `sudo -n /usr/local/bin/zapret-arch-helper` (see gui/helper/).

mod status;

use gtk4 as gtk;

use gtk::gdk;
use gtk::glib;
use gtk::gsk;
use gtk::prelude::*;
use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;
use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::rc::Rc;
use std::sync::mpsc::{channel, TryRecvError};
use std::time::Duration;

const APP_ID: &str = "ru.suwkie.zapret-arch";

enum Msg {
    Line(String),
    Done(Option<String>),
}

struct Ui {
    window: gtk::ApplicationWindow,
    banner: gtk::Revealer,
    banner_label: gtk::Label,
    state_icon: gtk::Image,
    state_label: gtk::Label,
    pid_label: gtk::Label,
    queue_label: gtk::Label,
    bar: gtk::ProgressBar,
    power: gtk::Button,
    power_icon: gtk::Image,
    power_label: gtk::Label,
    flag_games: gtk::ToggleButton,
    flag_voice: gtk::ToggleButton,
    flag_mc: gtk::ToggleButton,
    list: gtk::ListBox,
    list_scroll: gtk::ScrolledWindow,
    test_all: gtk::Button,
    count_label: gtk::Label,
    detail_slug: gtk::Label,
    detail_state: gtk::Label,
    apply_btn: gtk::Button,
    test_btn: gtk::Button,
    probe_header: gtk::Label,
    probe_btn: gtk::Button,
    probe_grid: gtk::Grid,
    log_view: gtk::TextView,
    busy: Cell<bool>,
    rebuilding: Cell<bool>,
    focused_once: Cell<bool>,
    suppress_flags: Cell<bool>,
    selected: RefCell<Option<String>>,
    status: RefCell<status::Status>,
    results: RefCell<BTreeMap<String, String>>,
    queue: Cell<u8>, // 0 unknown, 1 loaded, 2 missing
}

fn labelled(text: &str, classes: &[&str]) -> gtk::Label {
    let l = gtk::Label::builder().label(text).xalign(0.0).build();
    for c in classes {
        l.add_css_class(c);
    }
    l
}

fn spacer() -> gtk::Box {
    gtk::Box::builder().hexpand(true).build()
}

fn icon_label_button(icon: &str, text: &str) -> (gtk::Button, gtk::Image, gtk::Label) {
    let img = gtk::Image::from_icon_name(icon);
    let lbl = gtk::Label::new(Some(text));
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    row.append(&img);
    row.append(&lbl);
    let btn = gtk::Button::builder().child(&row).build();
    (btn, img, lbl)
}

fn spawn_work<T, F, G>(work: F, done: G)
where
    T: Send + 'static,
    F: FnOnce() -> T + Send + 'static,
    G: FnOnce(Option<T>) + 'static,
{
    let (tx, rx) = channel();
    std::thread::spawn(move || {
        let _ = tx.send(work());
    });
    let mut done = Some(done);
    glib::timeout_add_local(Duration::from_millis(40), move || match rx.try_recv() {
        Ok(v) => {
            if let Some(f) = done.take() {
                f(Some(v));
            }
            glib::ControlFlow::Break
        }
        Err(TryRecvError::Empty) => glib::ControlFlow::Continue,
        // Worker died without sending: still run the completion so the UI
        // cannot stay disabled forever.
        Err(TryRecvError::Disconnected) => {
            if let Some(f) = done.take() {
                f(None);
            }
            glib::ControlFlow::Break
        }
    });
}

impl Ui {
    fn set_busy(&self, on: bool, what: &str) {
        self.busy.set(on);
        let widgets: [gtk::Widget; 8] = [
            self.power.clone().upcast(),
            self.flag_games.clone().upcast(),
            self.flag_voice.clone().upcast(),
            self.flag_mc.clone().upcast(),
            self.apply_btn.clone().upcast(),
            self.test_btn.clone().upcast(),
            self.probe_btn.clone().upcast(),
            self.test_all.clone().upcast(),
        ];
        for w in widgets {
            w.set_sensitive(!on);
        }
        self.bar.set_visible(on);
        if on {
            self.state_label.set_label(what);
        }
    }

    fn show_error(&self, text: &str) {
        self.banner_label.set_label(text);
        self.banner.set_reveal_child(true);
        self.load_log();
    }

    fn hide_banner(&self) {
        self.banner.set_reveal_child(false);
    }

    fn push_log_line(&self, text: &str) {
        let buf = self.log_view.buffer();
        let mut end = buf.end_iter();
        if !text.is_empty() {
            buf.insert(&mut end, text);
        }
    }

    fn load_log(&self) {
        let view = self.log_view.clone();
        spawn_work(
            || {
                let out = Command::new("journalctl")
                    .args([
                        "-u",
                        "zapret-arch.service",
                        "-n",
                        "200",
                        "--no-pager",
                        "-o",
                        "short-iso",
                    ])
                    .output();
                let text = match out {
                    Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).to_string(),
                    Ok(o) => String::from_utf8_lossy(&o.stderr).to_string(),
                    Err(e) => format!("журнал недоступен: {e}"),
                };
                if text.trim().is_empty() {
                    "журнал пуст".to_string()
                } else {
                    text
                }
            },
            move |text: Option<String>| {
                let Some(text) = text else { return };
                view.buffer().set_text(text.trim_end());
                let mut end = view.buffer().end_iter();
                view.buffer().place_cursor(&end);
                view.scroll_to_iter(&mut end, 0.0, false, 0.0, 0.0);
            },
        );
    }

    fn render(&self) {
        let st = self.status.borrow();
        let active = st.service == "active";
        // status icon and word
        for c in ["state-ok", "state-warn", "state-error", "dim-label"] {
            self.state_icon.remove_css_class(c);
            self.state_label.remove_css_class(c);
        }
        if active {
            self.state_icon.set_icon_name(Some("emblem-ok-symbolic"));
            self.state_icon.add_css_class("state-ok");
            self.state_label.add_css_class("state-ok");
            self.state_label.set_label("активно");
        } else if st.service == "failed" {
            self.state_icon.add_css_class("state-warn");
            self.state_icon.set_icon_name(Some("dialog-warning-symbolic"));
            self.state_label.set_label("сбой");
        } else {
            self.state_icon.set_icon_name(Some("media-playback-stop-symbolic"));
            self.state_icon.add_css_class("dim-label");
            self.state_label.set_label("остановлено");
        }
        self.pid_label.set_label(&match st.pid {
            Some(p) => format!("nfqws: {p}"),
            None => "nfqws: нет процесса".into(),
        });
        self.queue_label.set_label(match self.queue.get() {
            1 => "очередь 201: загружена",
            2 => "очередь 201: нет",
            _ => "очередь 201: нет доступа (root)",
        });
        // power button
        if active {
            self.power_icon.set_icon_name(Some("media-playback-stop-symbolic"));
            self.power_label.set_label("выключить");
            self.power.remove_css_class("suggested-action");
        } else {
            self.power_icon.set_icon_name(Some("media-playback-start-symbolic"));
            self.power_label.set_label("включить");
            self.power.add_css_class("suggested-action");
        }
        // flags, without firing their handlers
        self.suppress_flags.set(true);
        self.flag_games.set_active(st.games);
        self.flag_voice.set_active(st.voice);
        self.flag_mc.set_active(st.minecraft);
        self.suppress_flags.set(false);
        drop(st);

        self.rebuild_list();
        self.render_detail();
        let has_strategy = self.status.borrow().strategy.is_some();
        self.power.set_sensitive(has_strategy && !self.busy.get());
        if !has_strategy {
            self.power.set_tooltip_text(Some("сначала примените стратегию"));
        }
    }

    fn rebuild_list(&self) {
        self.rebuilding.set(true);
        let vadj = self.list_scroll.vadjustment();
        let scroll_top = vadj.value();
        while let Some(child) = self.list.first_child() {
            self.list.remove(&child);
        }
        let results = self.results.borrow();
        let strategies = status::strategies();
        self.test_all.set_sensitive(!strategies.is_empty());
        self.count_label.set_label(&strategies.len().to_string());
        let current = self.status.borrow().strategy.clone();
        let selected = self.selected.borrow().clone();
        let mut built: Vec<(String, gtk::ListBoxRow)> = Vec::new();
        for slug in &strategies {
            let row = gtk::ListBoxRow::builder().build();
            row.set_activatable(false);
            let h = gtk::Box::new(gtk::Orientation::Horizontal, 6);
            h.set_size_request(-1, 32);
            let mark = if Some(slug) == current.as_ref() {
                let icon = gtk::Image::from_icon_name("emblem-ok-symbolic");
                icon.add_css_class("applied");
                icon
            } else {
                gtk::Image::new()
            };
            mark.set_size_request(14, 14);
            h.append(&mark);
            let name = labelled(slug, &["monospace"]);
            name.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
            name.set_hexpand(true);
            if Some(slug) == current.as_ref() {
                name.add_css_class("heading");
            }
            name.set_tooltip_text(Some(slug));
            h.append(&name);
            let score = results.get(slug).cloned().unwrap_or_else(|| "—".into());
            let s = labelled(&score, &["monospace", "dim-label"]);
            s.set_xalign(1.0);
            s.set_width_chars(4);
            h.append(&s);
            row.set_child(Some(&h));
            row.set_tooltip_text(Some(slug));
            self.list.append(&row);
            built.push((slug.clone(), row));
        }
        if strategies.is_empty() {
            let row = gtk::ListBoxRow::builder().selectable(false).activatable(false).build();
            row.set_child(Some(&labelled(
                "стратегий нет · нет профилей",
                &["dim-label", "caption"],
            )));
            self.list.append(&row);
        }
        // select the current strategy unless the user picked another
        let want = selected.or(current);
        if let Some((_, row)) = built.iter().find(|(slug, _)| Some(slug) == want.as_ref()) {
            self.list.select_row(Some(row));
        }
        self.rebuilding.set(false);
        vadj.set_value(scroll_top);
    }

    /// The row the detail column describes: the user's pick, else the applied one.
    fn choice(&self) -> Option<String> {
        self.selected
            .borrow()
            .clone()
            .or_else(|| self.status.borrow().strategy.clone())
    }

    fn render_detail(&self) {
        let st = self.status.borrow();
        let sel = self.selected.borrow().clone();
        let shown = sel.clone().or_else(|| st.strategy.clone());
        match &shown {
            Some(slug) => {
                self.detail_slug.set_label(slug);
                let base = if Some(slug) == st.strategy.as_ref() {
                    "применена".to_string()
                } else {
                    match &st.strategy {
                        Some(cur) => format!("не применена · сейчас {cur}"),
                        None => "не применена · стратегия не выбрана".to_string(),
                    }
                };
                let test = match self.results.borrow().get(slug).map(String::as_str) {
                    Some(score) => format!("тест: {score}"),
                    None => "тест: нет данных".to_string(),
                };
                self.detail_state.set_label(&format!("{base} · {test}"));
                let applied = Some(slug) == st.strategy.as_ref();
                self.detail_state.remove_css_class("state-ok");
                self.detail_state.remove_css_class("state-warn");
                self.detail_state
                    .add_css_class(if applied { "state-ok" } else { "state-warn" });
                if applied {
                    self.apply_btn.remove_css_class("heading");
                } else {
                    self.apply_btn.add_css_class("heading");
                }
            }
            None => {
                self.detail_slug.set_label("—");
                self.detail_state.set_label("не применена · стратегия не выбрана");
            }
        }
        let probe_strategy = st.strategy.clone();
        self.probe_header.set_label(&match &probe_strategy {
            Some(s) => format!("проверка · {s}"),
            None => "проверка".into(),
        });
        let enabled = probe_strategy.is_some() && st.service == "active";
        drop(st);
        self.apply_btn.set_sensitive(shown.is_some() && !self.busy.get());
        self.test_btn.set_sensitive(shown.is_some() && !self.busy.get());
        self.probe_btn.set_sensitive(enabled && !self.busy.get());
        self.probe_btn.set_tooltip_text(if enabled {
            None
        } else {
            Some("включите обход для проверки")
        });
    }

    fn set_probe(&self, rows: Vec<(String, String)>) {
        while let Some(child) = self.probe_grid.first_child() {
            child.unparent();
        }
        for (i, (url, value)) in rows.iter().enumerate() {
            let u = labelled(url, &["monospace", "caption", "dim-label"]);
            u.set_ellipsize(gtk::pango::EllipsizeMode::End);
            u.set_tooltip_text(Some(url));
            let v = labelled(value, &["monospace", "caption"]);
            v.set_halign(gtk::Align::End);
            self.probe_grid.attach(&u, 0, i as i32, 1, 1);
            self.probe_grid.attach(&v, 1, i as i32, 1, 1);
        }
    }
}

/// Scroll the current strategy into view. Called once, after the window is
/// mapped: before that the rows are not realised and cannot be scrolled to.
fn scroll_to_current(ui: &Rc<Ui>) {
    if let Some(want) = ui.choice() {
        let mut i = 0;
        while let Some(row) = ui.list.row_at_index(i) {
            if row.tooltip_text().as_deref() == Some(want.as_str()) {
                ui.list.select_row(Some(&row));
                let r = row.clone();
                glib::idle_add_local_once(move || {
                    r.grab_focus();
                });
                ui.focused_once.set(true);
                break;
            }
            i += 1;
        }
    }
}

fn refresh(ui: &Rc<Ui>) {
    let ui2 = ui.clone();
    spawn_work(
        || {
            (
                status::read_status(),
                status::test_results(),
                status::queue_state(),
            )
        },
        move |res: Option<(status::Status, BTreeMap<String, String>, Option<bool>)>| {
            let Some((st, results, queue)) = res else {
                return;
            };
            ui2.status.replace(st);
            ui2.results.replace(results);
            ui2.queue.set(match queue {
                Some(true) => 1,
                Some(false) => 2,
                None => 0,
            });
            ui2.render();
            if !ui2.focused_once.get() {
                // rows are realised after this callback, so scroll on the next idle
                let ui3 = ui2.clone();
                glib::idle_add_local_once(move || scroll_to_current(&ui3));
            }
        },
    );
}

fn run_helper(ui: &Rc<Ui>, what: &str, args: Vec<String>) {
    if ui.busy.get() {
        return;
    }
    ui.set_busy(true, what);
    let ui2 = ui.clone();
    spawn_work(
        move || {
            let borrowed: Vec<&str> = args.iter().map(String::as_str).collect();
            status::helper(&borrowed)
        },
        move |res: Option<Result<String, String>>| {
            ui2.set_busy(false, "");
            let res = match res {
                Some(r) => r,
                None => Err("операция прервана".to_string()),
            };
            match res {
                Ok(text) => {
                    ui2.hide_banner();
                    if !text.trim().is_empty() {
                        ui2.push_log_line(&format!("\n{text}\n"));
                    }
                }
                Err(e) => {
                    let msg = if e.contains("not permitted") || e.contains("Not authorized") {
                        "запрос прав отменён".to_string()
                    } else if e.contains("No such file") {
                        "sudo не настроен · переустановите GUI: sudo ./install-gui.sh".to_string()
                    } else {
                        e
                    };
                    ui2.show_error(&msg);
                }
            }
            refresh(&ui2);
        },
    );
}

fn do_probe(ui: &Rc<Ui>) {
    if ui.busy.get() {
        return;
    }
    ui.set_busy(true, "проверяется…");
    ui.set_probe(Vec::new());
    let ui2 = ui.clone();
    spawn_work(
        || status::cli(&["probe"]),
        move |res: Option<Result<String, String>>| {
            ui2.set_busy(false, "");
            let res = match res {
                Some(r) => r,
                None => Err("операция прервана".to_string()),
            };
            match res {
                Ok(text) => {
                    let (rows, all_failed) = parse_probe(&text);
                    if rows.is_empty() {
                        ui2.show_error("probe не вернул результатов · проверьте /usr/local/lib/zapret-arch");
                    } else if all_failed {
                        ui2.set_probe(rows);
                        ui2.show_error("нет ответа ни от одного адреса · проверьте сеть и dns");
                    } else {
                        ui2.set_probe(rows);
                        ui2.hide_banner();
                    }
                }
                Err(e) => ui2.show_error(&e),
            }
        },
    );
}

fn open_test(ui: &Rc<Ui>, target: String) {
    if ui.busy.get() {
        return;
    }
    ui.set_busy(true, "идёт тест…");
    let win = gtk::Window::builder()
        .title("тест стратегий")
        .modal(true)
        .transient_for(&ui.window)
        .default_width(560)
        .default_height(400)
        .build();
    win.set_titlebar(Some(&gtk::HeaderBar::new()));

    let root = gtk::Box::new(gtk::Orientation::Vertical, 12);
    root.set_margin_top(12);
    root.set_margin_bottom(12);
    root.set_margin_start(12);
    root.set_margin_end(12);

    let note = labelled(
        "тест по очереди перезапускает службу. связь может пропадать на минуту.",
        &["dim-label"],
    );
    note.set_wrap(true);
    root.append(&note);

    let view = gtk::TextView::builder()
        .editable(false)
        .cursor_visible(false)
        .monospace(true)
        .build();
    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Automatic)
        .vscrollbar_policy(gtk::PolicyType::Automatic)
        .vexpand(true)
        .child(&view)
        .build();
    root.append(&scroll);

    let footer = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    footer.set_halign(gtk::Align::End);
    let counter = labelled("идёт тест…", &["dim-label"]);
    let close = gtk::Button::with_label("закрыть");
    close.set_sensitive(false);
    footer.append(&counter);
    footer.append(&close);
    root.append(&footer);
    win.set_child(Some(&root));

    let win2 = win.clone();
    close.connect_clicked(move |_| win2.close());
    win.present();

    let (tx, rx) = channel::<Msg>();
    let target_for_child = target.clone();
    std::thread::spawn(move || {
        let mut child = match Command::new("sudo")
            .arg("-n")
            .arg(status::HELPER)
            .arg("test")
            .arg(&target_for_child)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
        {
            Ok(c) => c,
            Err(e) => {
                let _ = tx.send(Msg::Done(Some(format!("не запускается: {e}"))));
                return;
            }
        };
        let err_tx = tx.clone();
        if let Some(err) = child.stderr.take() {
            std::thread::spawn(move || {
                for line in BufReader::new(err).lines().map_while(Result::ok) {
                    if err_tx.send(Msg::Line(line)).is_err() {
                        break;
                    }
                }
            });
        }
        if let Some(out) = child.stdout.take() {
            for line in BufReader::new(out).lines().map_while(Result::ok) {
                if tx.send(Msg::Line(line)).is_err() {
                    break;
                }
            }
        }
        let status = child.wait();
        let err = match status {
            Ok(s) if s.success() => None,
            Ok(s) => Some(format!("тест завершился с кодом {}", s.code().unwrap_or(-1))),
            Err(e) => Some(format!("{e}")),
        };
        let _ = tx.send(Msg::Done(err));
    });

    let counter2 = counter.clone();
    let close2 = close.clone();
    let view2 = view.clone();
    let ui3 = ui.clone();
    glib::timeout_add_local(Duration::from_millis(80), move || {
        let mut done = false;
        loop {
            let msg = match rx.try_recv() {
                Ok(m) => m,
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => {
                    counter2.set_label("тест прерван");
                    close2.set_sensitive(true);
                    done = true;
                    break;
                }
            };
            match msg {
                Msg::Line(line) => {
                    let buf = view2.buffer();
                    let mut end = buf.end_iter();
                    buf.insert(&mut end, &format!("{line}\n"));
                    let mut end = view2.buffer().end_iter();
                    view2.buffer().place_cursor(&end);
                    view2.scroll_to_iter(&mut end, 0.0, false, 0.0, 0.0);
                    if let Some(rest) = line.strip_prefix('[') {
                        if let Some((i, total)) = rest.split_once('/') {
                            let total: String =
                                total.chars().take_while(|c| c.is_ascii_digit()).collect();
                            counter2.set_label(&format!("{i} из {total}"));
                        }
                    }
                }
                Msg::Done(err) => {
                    done = true;
                    ui3.set_busy(false, "");
                    match err {
                        Some(e) => {
                            counter2.set_label(&e);
                        }
                        None => {
                            let text = counter2.label().to_string();
                            if text.contains(" из ") {
                                counter2.set_label(&format!("тест завершён: {text}"));
                            } else {
                                counter2.set_label("тест завершён");
                            }
                        }
                    }
                    close2.set_sensitive(true);
                    refresh(&ui3);
                }
            }
        }
        if done {
            glib::ControlFlow::Break
        } else {
            glib::ControlFlow::Continue
        }
    });
}

fn build_ui(app: &gtk::Application) {
    let window = gtk::ApplicationWindow::builder()
        .application(app)
        .title("zapret-arch")
        .icon_name("ru.suwkie.zapret-arch")
        .default_width(860)
        .default_height(620)
        .build();
    window.set_size_request(720, 520);

    // --- header bar
    let header = gtk::HeaderBar::new();
    header.set_show_title_buttons(false);
    header.pack_start(&labelled("zapret-arch", &["title"]));
    // keep the window title for the taskbar, but stop the bar from drawing it twice
    header.set_title_widget(Some(&gtk::Box::new(gtk::Orientation::Horizontal, 0)));
    let refresh_btn = gtk::Button::builder()
        .icon_name("view-refresh")
        .tooltip_text("обновить состояние")
        .build();
    refresh_btn.add_css_class("flat");
    refresh_btn.add_css_class("hdr-btn");
    // Caption buttons drawn as text: theme icon glyphs are near-black and
    // disappear on this bar. Same three actions as the window manager's.
    let controls = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    let caption = |label: &str, tip: &str, extra: Option<&str>| {
        let b = gtk::Button::with_label(label);
        b.add_css_class("winbtn");
        if let Some(c) = extra {
            b.add_css_class(c);
        }
        b.set_tooltip_text(Some(tip));
        b.set_size_request(30, 28);
        b
    };
    let min_btn = caption("–", "свернуть", None);
    let max_btn = caption("□", "развернуть", None);
    let close_btn = caption("✕", "закрыть", Some("close"));
    for b in [&min_btn, &max_btn, &close_btn] {
        controls.append(b);
    }
    header.pack_end(&controls);
    header.pack_end(&refresh_btn);

    min_btn.connect_clicked({
        let w = window.clone();
        move |_| w.minimize()
    });
    max_btn.connect_clicked({
        let w = window.clone();
        move |_| {
            if w.is_maximized() {
                w.unmaximize();
            } else {
                w.maximize();
            }
        }
    });
    close_btn.connect_clicked({
        let w = window.clone();
        move |_| w.close()
    });
    window.set_titlebar(Some(&header));

    let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
    window.set_child(Some(&root));

    // --- error banner
    let banner = gtk::Revealer::builder()
        .transition_type(gtk::RevealerTransitionType::SlideDown)
        .transition_duration(120)
        .reveal_child(false)
        .build();
    let banner_row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    banner_row.add_css_class("error-banner");
    banner_row.set_margin_top(6);
    banner_row.set_margin_bottom(6);
    banner_row.set_margin_start(12);
    banner_row.set_margin_end(12);
    banner_row.append(&gtk::Image::from_icon_name("dialog-warning-symbolic"));
    let banner_label = labelled("", &[]);
    banner_label.set_wrap(true);
    banner_label.set_lines(2);
    banner_label.set_ellipsize(gtk::pango::EllipsizeMode::End);
    banner_label.set_hexpand(true);
    banner_row.append(&banner_label);
    let banner_close = gtk::Button::with_label("закрыть");
    banner_close.add_css_class("flat");
    banner_row.append(&banner_close);
    banner.set_child(Some(&banner_row));
    root.append(&banner);

    // --- body
    let body = gtk::Box::new(gtk::Orientation::Vertical, 12);
    body.set_margin_top(12);
    body.set_margin_bottom(12);
    body.set_margin_start(12);
    body.set_margin_end(12);
    root.append(&body);

    // status strip
    let strip = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    strip.add_css_class("status-strip");
    let state_icon = gtk::Image::from_icon_name("media-playback-stop-symbolic");
    let state_label = labelled("остановлено", &["heading"]);
    let pid_label = labelled("nfqws: нет процесса", &["monospace", "dim-label"]);
    pid_label.set_ellipsize(gtk::pango::EllipsizeMode::End);
    let queue_label = labelled("очередь 201: неизвестно", &["dim-label"]);
    queue_label.set_ellipsize(gtk::pango::EllipsizeMode::End);
    let bar = gtk::ProgressBar::builder().width_request(120).visible(false).build();
    bar.set_pulse_step(0.08);
    let (power, power_icon, power_label) =
        icon_label_button("media-playback-start-symbolic", "включить");
    power.add_css_class("suggested-action");
    strip.append(&state_icon);
    strip.append(&state_label);
    strip.append(&gtk::Separator::new(gtk::Orientation::Vertical));
    strip.append(&pid_label);
    strip.append(&gtk::Separator::new(gtk::Orientation::Vertical));
    strip.append(&queue_label);
    strip.append(&bar);
    strip.append(&spacer());
    strip.append(&power);
    body.append(&strip);

    // flags
    let flags = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    let flags_caption = labelled("флаги (не привязаны к стратегии)", &["caption", "dim-label"]);
    flags_caption.set_margin_end(6);
    flags.append(&flags_caption);
    let flag_games = gtk::ToggleButton::with_label("игры");
    let flag_voice = gtk::ToggleButton::with_label("голос discord");
    let flag_mc = gtk::ToggleButton::with_label("minecraft");
    for b in [&flag_games, &flag_voice, &flag_mc] {
        b.set_tooltip_text(Some("действует сразу · перезапустит службу, запросит пароль"));
        flags.append(b);
    }
    body.append(&flags);

    // panes
    let outer = gtk::Paned::new(gtk::Orientation::Vertical);
    outer.set_vexpand(true);
    outer.set_resize_end_child(false);
    outer.set_shrink_end_child(false);
    let inner = gtk::Paned::new(gtk::Orientation::Horizontal);
    inner.set_position(300);
    inner.set_resize_start_child(false);
    inner.set_shrink_start_child(false);

    // strategy list
    let list_box = gtk::Box::new(gtk::Orientation::Vertical, 0);
    list_box.set_width_request(260);
    let list_head = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    list_head.set_size_request(-1, 24);
    list_head.append(&labelled("стратегии", &["caption", "dim-label"]));
    let count_label = labelled("0", &["caption", "dim-label"]);
    list_head.append(&count_label);
    list_head.append(&spacer());
    let test_all = gtk::Button::with_label("тест всех");
    test_all.add_css_class("flat");
    test_all.add_css_class("caption");
    list_head.append(&test_all);
    list_box.append(&list_head);
    let list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::Single)
        .activate_on_single_click(false)
        .vexpand(true)
        .build();
    let list_scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vscrollbar_policy(gtk::PolicyType::Automatic)
        .vexpand(true)
        .child(&list)
        .build();
    list_box.append(&list_scroll);
    inner.set_start_child(Some(&list_box));

    // detail
    let detail_box = gtk::Box::new(gtk::Orientation::Vertical, 6);
    detail_box.set_margin_top(0);
    detail_box.set_margin_bottom(0);
    detail_box.set_margin_start(12);
    detail_box.set_margin_end(12);
    detail_box.set_width_request(360);
    let detail_slug = labelled("—", &["title-3", "monospace"]);
    detail_slug.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
    detail_box.append(&detail_slug);
    let detail_state = labelled("не применена · стратегия не выбрана", &["dim-label"]);
    detail_box.append(&detail_state);
    let detail_actions = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    detail_actions.set_margin_top(6);
    let apply_btn = gtk::Button::with_label("применить");
    let test_btn = gtk::Button::with_label("тест");
    detail_actions.append(&apply_btn);
    detail_actions.append(&test_btn);
    detail_box.append(&detail_actions);
    detail_box.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
    let probe_head = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    probe_head.set_margin_top(6);
    let probe_header = labelled("проверка", &["caption", "dim-label"]);
    probe_head.append(&probe_header);
    probe_head.append(&spacer());
    let probe_btn = gtk::Button::builder()
        .child(&{
            let row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
            row.append(&gtk::Image::from_icon_name("view-refresh"));
            row.append(&gtk::Label::new(Some("проверить")));
            row
        })
        .build();
    probe_btn.add_css_class("flat");
    probe_head.append(&probe_btn);
    detail_box.append(&probe_head);
    let probe_grid = gtk::Grid::builder()
        .column_spacing(12)
        .row_spacing(2)
        .build();
    detail_box.append(&probe_grid);
    let detail_scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vscrollbar_policy(gtk::PolicyType::Automatic)
        .child(&detail_box)
        .build();
    inner.set_end_child(Some(&detail_scroll));
    outer.set_start_child(Some(&inner));

    // log
    let log_box = gtk::Box::new(gtk::Orientation::Vertical, 0);
    log_box.add_css_class("log-pane");
    log_box.set_size_request(-1, 150);
    let log_head = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    log_head.set_size_request(-1, 24);
    // One label, not two: a separate "$" label sits on its own baseline and
    // never lines up with Cyrillic descenders.
    let log_title = labelled("", &["caption"]);
    // ">" instead of "$": no descender tail, so it sits on the same optical
    // line as Cyrillic lowercase.
    log_title.set_markup(
        r##"<span foreground="#19cb00">&gt;</span> <span foreground="#767676">журнал</span>"##,
    );
    log_head.append(&log_title);
    log_head.append(&spacer());
    let log_refresh = gtk::Button::with_label("обновить");
    log_refresh.add_css_class("flat");
    log_refresh.add_css_class("caption");
    let copy_btn = gtk::Button::with_label("копировать");
    copy_btn.add_css_class("flat");
    copy_btn.add_css_class("caption");
    log_head.append(&log_refresh);
    log_head.append(&copy_btn);
    log_box.append(&log_head);
    let log_view = gtk::TextView::builder()
        .editable(false)
        .cursor_visible(false)
        .monospace(true)
        .wrap_mode(gtk::WrapMode::None)
        .top_margin(4)
        .bottom_margin(6)
        .left_margin(8)
        .build();
    let log_scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Automatic)
        .vscrollbar_policy(gtk::PolicyType::Automatic)
        .vexpand(true)
        .child(&log_view)
        .build();
    log_box.append(&log_scroll);
    outer.set_end_child(Some(&log_box));
    body.append(&outer);

    let ui = Rc::new(Ui {
        window: window.clone(),
        banner,
        banner_label,
        state_icon,
        state_label,
        pid_label,
        queue_label,
        bar,
        power,
        power_icon,
        power_label,
        flag_games,
        flag_voice,
        flag_mc,
        list: list.clone(),
        list_scroll: list_scroll.clone(),
        test_all: test_all.clone(),
        count_label,
        detail_slug,
        detail_state,
        apply_btn,
        test_btn,
        probe_header,
        probe_btn: probe_btn.clone(),
        probe_grid,
        log_view,
        busy: Cell::new(false),
        rebuilding: Cell::new(false),
        focused_once: Cell::new(false),
        suppress_flags: Cell::new(false),
        selected: RefCell::new(None),
        status: RefCell::new(status::Status::default()),
        results: RefCell::new(BTreeMap::new()),
        queue: Cell::new(0),
    });

    // pulses while busy
    {
        let ui2 = ui.clone();
        glib::timeout_add_local(Duration::from_millis(120), move || {
            if ui2.busy.get() {
                ui2.bar.pulse();
                glib::ControlFlow::Continue
            } else {
                ui2.bar.set_fraction(0.0);
                glib::ControlFlow::Continue
            }
        });
    }

    // --- wiring
    refresh_btn.connect_clicked({
        let ui = ui.clone();
        move |_| refresh(&ui)
    });
    log_refresh.connect_clicked({
        let ui = ui.clone();
        move |_| ui.load_log()
    });
    banner_close.connect_clicked({
        let ui = ui.clone();
        move |_| ui.hide_banner()
    });
    copy_btn.connect_clicked({
        let ui = ui.clone();
        move |btn| {
            let buf = ui.log_view.buffer();
            let text = buf.text(&buf.start_iter(), &buf.end_iter(), false);
            let original = "копировать".to_string();
            let btn = btn.clone();
            btn.set_label("скопировано");
            let b = btn.clone();
            glib::timeout_add_local_once(Duration::from_millis(1500), move || {
                b.set_label(&original);
            });
            ui.window.clipboard().set_text(&text);
        }
    });

    ui.list.connect_row_selected({
        let ui = ui.clone();
        move |_, row| {
            if ui.rebuilding.get() {
                return;
            }
            let slug = row.and_then(|r| r.tooltip_text()).map(|s| s.to_string());
            ui.selected.replace(slug);
            ui.render_detail();
        }
    });

    ui.power.connect_clicked({
        let ui = ui.clone();
        move |_| {
            let active = ui.status.borrow().service == "active";
            let (verb, what) = if active {
                ("off", "выключается…")
            } else {
                ("on", "включается…")
            };
            run_helper(&ui, what, vec![verb.to_string()]);
        }
    });

    for (btn, name) in [
        (ui.flag_games.clone(), "games"),
        (ui.flag_voice.clone(), "voice"),
        (ui.flag_mc.clone(), "minecraft"),
    ] {
        let ui2 = ui.clone();
        btn.connect_toggled(move |b| {
            if ui2.suppress_flags.get() || ui2.rebuilding.get() {
                return;
            }
            let mode = if b.is_active() { "on" } else { "off" };
            let ui3 = ui2.clone();
            let name = name.to_string();
            // The toggle keeps its new state; refresh() re-reads state/ and puts
            // it back if the privileged call failed.
            run_helper(
                &ui3,
                "переключается…",
                vec!["preset".into(), name, mode.into()],
            );
        });
    }

    ui.apply_btn.connect_clicked({
        let ui = ui.clone();
        move |_| {
            let slug = ui
                .selected
                .borrow()
                .clone()
                .or_else(|| ui.status.borrow().strategy.clone());
            if let Some(slug) = slug {
                run_helper(&ui, &format!("применяется {slug}…"), vec!["apply".into(), slug]);
            }
        }
    });

    ui.test_btn.connect_clicked({
        let ui = ui.clone();
        move |_| {
            if ui.busy.get() {
                return;
            }
            let target = ui
                .selected
                .borrow()
                .clone()
                .or_else(|| ui.status.borrow().strategy.clone())
                .unwrap_or_else(|| "all".into());
            open_test(&ui, target);
        }
    });

    test_all.connect_clicked({
        let ui = ui.clone();
        move |_| {
            if ui.busy.get() {
                return;
            }
            open_test(&ui, "all".into())
        }
    });

    probe_btn.connect_clicked({
        let ui = ui.clone();
        move |_| do_probe(&ui)
    });

    ui.set_probe(vec![("—".into(), "не проверено".into())]);

    // initial load
    refresh(&ui);
    ui.load_log();
    window.present();
    let ui2 = ui.clone();
    glib::timeout_add_local_once(Duration::from_millis(400), move || scroll_to_current(&ui2));
    maybe_snapshot(&window);
}

/// The whole look lives in src/style.css so the design can change without
/// touching the widget tree.
fn load_css() {
    let provider = gtk::CssProvider::new();
    provider.load_from_data(include_str!("style.css"));
    if let Some(display) = gdk::Display::default() {
        gtk::style_context_add_provider_for_display(
            &display,
            &provider,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    }
}

extern "C" {
    #[link_name = "_exit"]
    fn hard_exit(code: i32) -> !;
}

/// Debug aid: ZAPRET_GUI_SNAP=/path.png renders the window to a PNG and exits.
/// Lets a window be inspected without bringing it to the front.
fn maybe_snapshot(window: &gtk::ApplicationWindow) {
    let Some(path) = std::env::var_os("ZAPRET_GUI_SNAP") else {
        return;
    };
    let window = window.clone();
    glib::timeout_add_local_once(Duration::from_millis(2500), move || {
        let (w, h) = (window.width(), window.height());
        if w > 0 && h > 0 {
            let paintable = gtk::WidgetPaintable::new(Some(&window));
            let snapshot = gtk::Snapshot::new();
            paintable.snapshot(&snapshot, f64::from(w), f64::from(h));
            if let Some(node) = snapshot.to_node() {
                if let Some(renderer) = window
                    .surface()
                    .and_then(|s| gsk::Renderer::for_surface(&s))
                {
                    let texture = renderer.render_texture(&node, None);
                    let _ = texture.save_to_png(&path);
                    // Skip destructors: GSK aborts when this renderer is dropped
                    // while the surface is still realised.
                    unsafe { hard_exit(0) };
                }
            }
        }
    });
}

fn main() -> glib::ExitCode {
    let app = gtk::Application::builder().application_id(APP_ID).build();
    app.connect_startup(|_| load_css());
    app.connect_activate(build_ui);
    app.run()
}

/// Parses `zapret-arch probe` stdout: one `url code 0.123s status` row per line.
/// Returns the display rows and whether every target came back 000.
fn parse_probe(text: &str) -> (Vec<(String, String)>, bool) {
    let mut rows = Vec::new();
    let mut all_failed = true;
    for line in text.lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() >= 3 && parts[0].starts_with("http") {
            let url = parts[0].to_string();
            let code = parts[1].to_string();
            if code != "000" {
                all_failed = false;
            }
            let value = if code == "000" {
                "000 · нет ответа".to_string()
            } else {
                let secs = parts[2].trim_end_matches('s').parse::<f64>().unwrap_or(0.0);
                format!("{code} · {:.2} с", secs).replace('.', ",")
            };
            rows.push((url, value));
        }
    }
    let failed = all_failed && !rows.is_empty();
    (rows, failed)
}

#[cfg(test)]
mod tests {
    use super::parse_probe;

    #[test]
    fn parses_probe_rows() {
        let text = "strategy: general-alt9\n\nhttps://discord.com                      200  0.122103s  ok\nhttps://youtu.be                         000  0s  FAIL (no HTTP response)\n";
        let (rows, all_failed) = parse_probe(text);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].0, "https://discord.com");
        assert_eq!(rows[0].1, "200 · 0,12 с");
        assert_eq!(rows[1].1, "000 · нет ответа");
        assert!(!all_failed, "one reachable target means not all failed");
    }

    #[test]
    fn all_failed_only_when_everything_is_000() {
        let text = "https://a.example  000  0s  FAIL\nhttps://b.example  000  0s  FAIL\n";
        assert!(parse_probe(text).1);
        assert!(parse_probe("").0.is_empty());
    }
}
