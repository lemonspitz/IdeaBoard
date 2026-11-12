using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using Microsoft.Win32;

namespace IdeaBoard
{
    static class Program
    {
        public const string PipeName = "IdeaBoard.OpenRequests";

        [STAThread]
        static int Main(string[] args)
        {
            bool test = args.Contains("--selftest");
            // One window: a second launch (double-clicked file, join link) hands its argument to the first.
            Mutex mutex = null;
            if (!test)
            {
                mutex = new Mutex(true, "IdeaBoard.SingleInstance", out bool first);
                if (!first)
                {
                    try
                    {
                        using (var c = new NamedPipeClientStream(".", PipeName, PipeDirection.Out))
                        {
                            c.Connect(3000);
                            var w = new StreamWriter(c, new UTF8Encoding(false));
                            w.WriteLine(args.Length > 0 ? args[0] : "--activate");
                            w.Flush();
                        }
                        return 0;
                    }
                    catch { /* first instance not answering: carry on as a new window */ }
                }
            }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            var form = new MainForm(args);
            Application.Run(form);
            GC.KeepAlive(mutex);
            return form.ExitCode;
        }
    }

    sealed class MainForm : Form
    {
        const string Host = "app.ideaboard.local";
        const string FileExt = ".ideaboard";
        static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue, RecursionLimit = 256 };
        static string J(object o) => Json.Serialize(o);

        readonly string[] args;
        readonly WebView2 web = new WebView2 { Dock = DockStyle.Fill, DefaultBackgroundColor = Color.FromArgb(243, 243, 239) };
        readonly string supportDir, settingsPath, autosavePath;
        readonly bool selfTest;
        Dictionary<string, object> settings = new Dictionary<string, object>();
        string fileName;          // current .ideaboard file, or null
        string cloudBoard, cloudName = "", boardName = "Untitled board";
        bool dirty, ready;
        readonly Queue<string> pending = new Queue<string>();
        public int ExitCode;

        public MainForm(string[] args)
        {
            this.args = args;
            selfTest = args.Contains("--selftest");
            supportDir = Environment.GetEnvironmentVariable("IDEABOARD_SUPPORT")
                ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Idea Board");
            Directory.CreateDirectory(supportDir);
            settingsPath = Path.Combine(supportDir, "settings.json");
            autosavePath = Path.Combine(supportDir, "autosave" + FileExt);
            LoadSettings();

            Text = "Idea Board";
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
            MinimumSize = new Size(640, 480);
            StartPosition = FormStartPosition.CenterScreen;
            Size = new Size(1320, 860);
            LoadBounds();
            Controls.Add(web);
            Load += async (s, e) => await StartAsync();
            FormClosing += (s, e) => SaveBounds();

            if (!selfTest)
            {
                RegisterShellIntegration();
                StartPipeServer();
            }
            foreach (var a in args.Where(a => !a.StartsWith("--"))) pending.Enqueue(a);
        }

        // ---------- settings ----------
        void LoadSettings()
        {
            try { if (File.Exists(settingsPath)) settings = Json.Deserialize<Dictionary<string, object>>(File.ReadAllText(settingsPath)) ?? settings; }
            catch { settings = new Dictionary<string, object>(); }
        }
        void SaveSettings()
        {
            try { File.WriteAllText(settingsPath, J(settings), new UTF8Encoding(false)); } catch { }
        }
        string Setting(string k) => settings.TryGetValue(k, out var v) && v != null ? v.ToString() : null;
        void Set(string k, object v) { settings[k] = v; SaveSettings(); }

        void LoadBounds()
        {
            try
            {
                var b = Setting("bounds");
                if (b == null) return;
                var p = b.Split(',').Select(int.Parse).ToArray();
                var r = new Rectangle(p[0], p[1], p[2], p[3]);
                if (Screen.AllScreens.Any(s => s.WorkingArea.IntersectsWith(r))) { StartPosition = FormStartPosition.Manual; Bounds = r; }
                if (p.Length > 4 && p[4] == 1) WindowState = FormWindowState.Maximized;
            }
            catch { }
        }
        void SaveBounds()
        {
            if (selfTest) return;
            var r = WindowState == FormWindowState.Normal ? Bounds : RestoreBounds;
            Set("bounds", $"{r.X},{r.Y},{r.Width},{r.Height},{(WindowState == FormWindowState.Maximized ? 1 : 0)}");
        }

        // ---------- web view ----------
        async Task StartAsync()
        {
            var webDir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "web");
            var dataDir = Environment.GetEnvironmentVariable("IDEABOARD_WEBDATA")
                ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Idea Board", "WebView2");
            CoreWebView2Environment env;
            try
            {
                env = await CoreWebView2Environment.CreateAsync(null, dataDir);
                await web.EnsureCoreWebView2Async(env);
            }
            catch (WebView2RuntimeNotFoundException)
            {
                if (MessageBox.Show(this, "Idea Board needs the Microsoft Edge WebView2 Runtime, which is part of Windows 10 and 11 but seems to be missing.\n\nOpen the download page now?",
                        "Idea Board", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) == DialogResult.Yes)
                    Process.Start("https://go.microsoft.com/fwlink/p/?LinkId=2124703");
                ExitCode = 2; Close(); return;
            }
            var cw = web.CoreWebView2;
            cw.SetVirtualHostNameToFolderMapping(Host, webDir, CoreWebView2HostResourceAccessKind.Allow);
            cw.Settings.IsZoomControlEnabled = false;          // Ctrl+wheel zooms the board, not the page
            cw.Settings.AreBrowserAcceleratorKeysEnabled = false; // Ctrl+S/O/N/E reach the board
            cw.Settings.IsStatusBarEnabled = false;
            cw.Settings.AreDefaultContextMenusEnabled = false;
            cw.Settings.AreDevToolsEnabled = Environment.GetEnvironmentVariable("IDEABOARD_DEVTOOLS") == "1";
            cw.Settings.IsGeneralAutofillEnabled = false;
            cw.WebMessageReceived += (s, e) => { try { OnMessage(e.TryGetWebMessageAsString()); } catch (Exception x) { Debug.WriteLine(x); } };
            cw.NewWindowRequested += (s, e) => { e.Handled = true; OpenExternal(e.Uri); };
            cw.NavigationStarting += (s, e) =>
            {
                if (!new Uri(e.Uri).Host.Equals(Host, StringComparison.OrdinalIgnoreCase)) { e.Cancel = true; OpenExternal(e.Uri); }
            };
            cw.NavigationCompleted += async (s, e) =>
            {
                ready = true;
                while (pending.Count > 0) HandleArgument(pending.Dequeue());
                if (selfTest) await RunSelfTestAsync();
            };
            await cw.AddScriptToExecuteOnDocumentCreatedAsync(BootScript());
            cw.Navigate($"https://{Host}/index.html");
        }

        string BootScript()
        {
            var sb = new StringBuilder();
            // The page talks to its host through window.webkit.messageHandlers.board (as in the Mac app);
            // here that forwards to WebView2's message channel.
            sb.Append("window.__IDEABOARD_PLATFORM='win';");
            sb.Append("window.webkit={messageHandlers:{board:{postMessage:function(m){window.chrome.webview.postMessage(JSON.stringify(m));}}}};");
            if (Environment.GetEnvironmentVariable("IDEABOARD_EMULATOR") == "1") sb.Append("window.__IDEABOARD_EMULATOR=true;");
            // Collaboration identity: random per-install device ID and a remembered display name.
            var device = Setting("deviceID");
            if (string.IsNullOrEmpty(device)) { device = Guid.NewGuid().ToString(); Set("deviceID", device); }
            var ident = new Dictionary<string, object> { ["id"] = device, ["defaultName"] = DefaultName() };
            var name = Setting("displayName");
            if (!string.IsNullOrEmpty(name)) ident["name"] = name;
            sb.Append("window.__IDEABOARD_DEVICE=" + J(ident) + ";");
            if (!selfTest && File.Exists(autosavePath))
            {
                try
                {
                    sb.Append("window.__IDEABOARD_INITIAL=" + J(File.ReadAllText(autosavePath, Encoding.UTF8)) + ";");
                    if (Setting("dirty") == "True") sb.Append("window.__IDEABOARD_DIRTY=true;");
                    var last = Setting("lastFile");
                    if (!string.IsNullOrEmpty(last) && File.Exists(last)) fileName = last;
                }
                catch { }
            }
            UpdateTitle();
            return sb.ToString();
        }

        [DllImport("secur32.dll", CharSet = CharSet.Unicode)] static extern bool GetUserNameEx(int format, StringBuilder name, ref uint size);

        static string DefaultName()
        {
            try
            {
                // Windows display name (e.g. "Ana Putri") when the account has one, otherwise the sign-in name.
                uint n = 256; var sb = new StringBuilder((int)n);
                if (GetUserNameEx(3 /* NameDisplay */, sb, ref n) && sb.ToString().Trim().Length > 0) return sb.ToString().Trim().Split(' ')[0];
            }
            catch { }
            return Environment.UserName;
        }

        Task<string> Eval(string js) => web.CoreWebView2.ExecuteScriptAsync(js);
        async Task<string> EvalString(string js)
        {
            var r = await Eval(js);
            if (string.IsNullOrEmpty(r) || r == "null") return null;
            try { return Json.Deserialize<string>(r); } catch { return null; }
        }

        // ---------- messages from the page ----------
        void OnMessage(string raw)
        {
            if (raw == null) return;
            var m = Json.Deserialize<Dictionary<string, object>>(raw);
            if (m == null || !m.TryGetValue("cmd", out var c)) return;
            string Str(string k) => m.TryGetValue(k, out var v) && v != null ? v.ToString() : null;
            switch (c as string)
            {
                case "autosave":
                    if (!selfTest && Str("data") is string d) { try { File.WriteAllText(autosavePath, d, new UTF8Encoding(false)); } catch { } }
                    break;
                case "dirty":
                    dirty = m.TryGetValue("value", out var dv) && dv is bool b && b;
                    if (!selfTest) Set("dirty", dirty);
                    UpdateTitle();
                    break;
                case "save": _ = SaveAsync(false); break;
                case "saveAs": _ = SaveAsync(true); break;
                case "open": ConfirmDiscard(OpenDialog); break;
                case "new": ConfirmDiscard(async () => { SetFile(null); await Eval("app.newBoard()"); }); break;
                case "export": _ = ExportAsync(); break;
                case "name": boardName = Str("value") ?? boardName; UpdateTitle(); break;
                case "join": if (Str("code") is string code) Join(code); break;
                case "copy": if (Str("value") is string t) { try { Clipboard.SetText(t); } catch { } } break;
                case "identity": if (!selfTest && !string.IsNullOrEmpty(Str("name"))) Set("displayName", Str("name")); break;
                case "cloud":
                    cloudBoard = string.IsNullOrEmpty(Str("id")) ? null : Str("id");
                    cloudName = Str("name") ?? "";
                    if (cloudBoard != null) { SetFile(null); dirty = false; }
                    UpdateTitle();
                    break;
            }
        }

        void UpdateTitle()
        {
            string t;
            if (cloudBoard != null) t = (string.IsNullOrEmpty(cloudName) ? "Untitled board" : cloudName) + " (saved to your account)";
            else if (fileName != null) t = Path.GetFileNameWithoutExtension(fileName);
            else t = boardName;
            void apply() => Text = (dirty ? "• " : "") + t + " — Idea Board";
            if (InvokeRequired) BeginInvoke((Action)apply); else apply();
        }

        void SetFile(string path)
        {
            fileName = path;
            if (!selfTest) Set("lastFile", path);
            UpdateTitle();
        }

        // ---------- files ----------
        void ConfirmDiscard(Action then)
        {
            if (!dirty) { then(); return; }
            var r = MessageBox.Show(this, "Save changes to this board?\n\nYour changes will be lost if you don't save them.", "Idea Board",
                MessageBoxButtons.YesNoCancel, MessageBoxIcon.Question);
            if (r == DialogResult.Cancel) return;
            if (r == DialogResult.No) { then(); return; }
            _ = SaveAsync(false, then);
        }

        void OpenDialog()
        {
            using (var d = new OpenFileDialog { Filter = "Idea Board (*.ideaboard)|*.ideaboard|JSON (*.json)|*.json|All files|*.*", Title = "Open board" })
                if (d.ShowDialog(this) == DialogResult.OK) _ = OpenPathAsync(d.FileName);
        }

        async Task OpenPathAsync(string path)
        {
            string data;
            try { data = File.ReadAllText(path, Encoding.UTF8); }
            catch (Exception x) { MessageBox.Show(this, "Couldn't read " + Path.GetFileName(path) + ".\n\n" + x.Message, "Idea Board", MessageBoxButtons.OK, MessageBoxIcon.Error); return; }
            var name = Path.GetFileNameWithoutExtension(path);
            var ok = await Eval($"app.load({J(data)}, {J(name)})");
            if (ok == "true")
            {
                SetFile(path); dirty = false; UpdateTitle();
                await Eval("app.markSaved(null)");
            }
        }

        async Task SaveAsync(bool saveAs, Action then = null)
        {
            var path = saveAs ? null : fileName;
            if (path == null)
            {
                var name = await EvalString("app.name()") ?? "Untitled board";
                using (var d = new SaveFileDialog { Filter = "Idea Board (*.ideaboard)|*.ideaboard", FileName = SafeName(name) + FileExt, Title = "Save board", AddExtension = true, DefaultExt = "ideaboard" })
                {
                    if (d.ShowDialog(this) != DialogResult.OK) return;
                    path = d.FileName;
                }
            }
            var data = await EvalString("app.serialize()");
            if (data == null) return;
            try { File.WriteAllText(path, data, new UTF8Encoding(false)); }
            catch (Exception x) { MessageBox.Show(this, "Couldn't save.\n\n" + x.Message, "Idea Board", MessageBoxButtons.OK, MessageBoxIcon.Error); return; }
            SetFile(path);
            dirty = false; UpdateTitle();
            await Eval($"app.markSaved({J(Path.GetFileNameWithoutExtension(path))})");
            then?.Invoke();
        }

        async Task ExportAsync()
        {
            var url = await EvalString("app.exportPNG()");
            if (url == null || !url.Contains(","))
            {
                MessageBox.Show(this, "Add something to the board first.", "Nothing to export yet", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            var bytes = Convert.FromBase64String(url.Substring(url.IndexOf(',') + 1));
            var name = await EvalString("app.name()") ?? "Board";
            using (var d = new SaveFileDialog { Filter = "PNG image (*.png)|*.png", FileName = SafeName(name) + ".png", Title = "Export as PNG" })
                if (d.ShowDialog(this) == DialogResult.OK)
                {
                    try { File.WriteAllBytes(d.FileName, bytes); }
                    catch (Exception x) { MessageBox.Show(this, x.Message, "Idea Board", MessageBoxButtons.OK, MessageBoxIcon.Error); }
                }
        }

        static string SafeName(string n)
        {
            foreach (var ch in Path.GetInvalidFileNameChars()) n = n.Replace(ch, '-');
            n = n.Trim();
            return n.Length == 0 ? "Board" : n;
        }

        // ---------- links, single instance, shell integration ----------
        void Join(string code) => ConfirmDiscard(async () => { SetFile(null); dirty = false; await Eval($"app.join({J(code)}, true)"); });

        void HandleArgument(string a)
        {
            if (string.IsNullOrWhiteSpace(a) || a == "--activate") { ShowWindowFront(); return; }
            if (!ready) { pending.Enqueue(a); return; }
            if (a.StartsWith("ideaboard:", StringComparison.OrdinalIgnoreCase))
            {
                // ideaboard://join/CODE or ideaboard://board/ID
                var parts = a.Substring("ideaboard:".Length).Trim('/').Split('/');
                if (parts.Length >= 2 && parts[0] == "board") { _ = Eval($"app.openBoard({J(parts[1])})"); }
                else if (parts.Length >= 1) Join(parts[parts.Length - 1]);
                return;
            }
            if (File.Exists(a)) ConfirmDiscard(() => { _ = OpenPathAsync(a); });
        }

        void ShowWindowFront()
        {
            if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
            Activate();
        }

        void StartPipeServer()
        {
            var t = new Thread(() =>
            {
                while (true)
                {
                    try
                    {
                        using (var s = new NamedPipeServerStream(Program.PipeName, PipeDirection.In))
                        {
                            s.WaitForConnection();
                            var line = new StreamReader(s, Encoding.UTF8).ReadLine();
                            BeginInvoke((Action)(() => { ShowWindowFront(); HandleArgument(line); }));
                        }
                    }
                    catch { Thread.Sleep(500); }
                }
            }) { IsBackground = true, Name = "open-requests" };
            t.Start();
        }

        void OpenExternal(string uri)
        {
            try { if (uri.StartsWith("http://") || uri.StartsWith("https://") || uri.StartsWith("mailto:")) Process.Start(uri); } catch { }
        }

        [DllImport("shell32.dll")] static extern void SHChangeNotify(int eventId, int flags, IntPtr a, IntPtr b);

        // Per-user (no admin needed): .ideaboard files open in Idea Board and ideaboard:// links join boards.
        static void RegisterShellIntegration()
        {
            try
            {
                var exe = Application.ExecutablePath;
                var open = $"\"{exe}\" \"%1\"";
                using (var k = Registry.CurrentUser.CreateSubKey(@"Software\Classes\.ideaboard")) k.SetValue("", "IdeaBoard.Board");
                using (var k = Registry.CurrentUser.CreateSubKey(@"Software\Classes\IdeaBoard.Board"))
                {
                    k.SetValue("", "Idea Board");
                    using (var i = k.CreateSubKey("DefaultIcon")) i.SetValue("", $"\"{exe}\",0");
                    using (var c = k.CreateSubKey(@"shell\open\command")) c.SetValue("", open);
                }
                using (var k = Registry.CurrentUser.CreateSubKey(@"Software\Classes\ideaboard"))
                {
                    k.SetValue("", "URL:Idea Board link");
                    k.SetValue("URL Protocol", "");
                    using (var i = k.CreateSubKey("DefaultIcon")) i.SetValue("", $"\"{exe}\",0");
                    using (var c = k.CreateSubKey(@"shell\open\command")) c.SetValue("", open);
                }
                SHChangeNotify(0x08000000, 0, IntPtr.Zero, IntPtr.Zero); // refresh file icons
            }
            catch { }
        }

        // ---------- self-test (used by CI on a real Windows machine) ----------
        async Task RunSelfTestAsync()
        {
            var outPath = args.SkipWhile(a => a != "--selftest").Skip(1).FirstOrDefault(a => !a.StartsWith("--"));
            var shot = args.SkipWhile(a => a != "--selftest").Skip(2).FirstOrDefault(a => !a.StartsWith("--"));
            var result = new Dictionary<string, object>();
            try
            {
                await Task.Delay(4000); // let the page boot and Firebase load
                result["native"] = await Eval("!!window.webkit && typeof app === 'object'");
                result["cloud"] = await Eval("JSON.stringify(app._cloud())");
                result["authScreen"] = await Eval("(document.querySelector('#auth h2')||{}).textContent || ''");
                result["rtc"] = await Eval("typeof RTCPeerConnection");
                result["ctrlLabels"] = await Eval("document.querySelector('#undobtn').title");
                // Draw something without the sign-in screen in the way, then export.
                await Eval("document.querySelector('#auth').classList.remove('show'); app.newBoard(); document.querySelector('#menubtn').click(); document.querySelector('[data-m=\"tpl:Flowchart\"]').click(); 1");
                await Task.Delay(800);
                result["items"] = await Eval("app._state().items.length");
                var png = await EvalString("app.exportPNG()");
                result["pngBytes"] = png == null ? 0 : png.Length;
                // Save + reopen round trip through the native file code.
                var tmp = Path.Combine(supportDir, "roundtrip" + FileExt);
                File.WriteAllText(tmp, await EvalString("app.serialize()"), new UTF8Encoding(false));
                await OpenPathAsync(tmp);
                result["reopenedItems"] = await Eval("app._state().items.length");
                result["title"] = Text;
                if (shot != null)
                {
                    using (var fs = File.Create(shot))
                        await web.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, fs);
                }
                result["ok"] = result["items"].ToString() == result["reopenedItems"].ToString() && (int)result["pngBytes"] > 1000;
            }
            catch (Exception x) { result["ok"] = false; result["error"] = x.ToString(); }
            if (outPath != null) File.WriteAllText(outPath, J(result), new UTF8Encoding(false));
            ExitCode = result.TryGetValue("ok", out var ok) && ok is bool b && b ? 0 : 1;
            Close();
        }
    }
}
