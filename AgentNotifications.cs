using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Toolkit.Uwp.Notifications;
[assembly: System.Reflection.AssemblyTitle("Agent Sessions")]
internal static class AgentNotifications {
    static readonly string Root=AppDomain.CurrentDomain.BaseDirectory;
    static readonly JavaScriptSerializer Json=new JavaScriptSerializer();
    static Form Dispatcher;
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr h,int command);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
    public class Request { public string Provider; public string SessionId; public string Name; public string Snippet; public DateTime CreatedUtc; }
    public class Target { public string Provider; public string SessionId; public long Hwnd; public int Pid; public int AgentPid; public DateTime AgentStarted; }
    public class Snapshot { public DateTime CreatedUtc; public Target[] Sessions; }
    static bool Valid(string provider,string id) { return (String.Equals(provider,"Codex",StringComparison.OrdinalIgnoreCase)||String.Equals(provider,"Claude",StringComparison.OrdinalIgnoreCase)) && id!=null && Regex.IsMatch(id,"\\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\\z",RegexOptions.IgnoreCase); }
    static void Log(string text) { try{File.AppendAllText(Path.Combine(Root,"native-notifications.log"),DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff")+" "+text+Environment.NewLine);}catch{} }
    static void ShowError(string message) {
        Dispatcher.BeginInvoke(new Action(delegate {MessageBox.Show(message+". Press Alt + backtick for current sessions.","Agent Sessions",MessageBoxButtons.OK,MessageBoxIcon.Information);}));
    }
    static Target Resolve(string provider,string id) {
        if(!Valid(provider,id)) throw new InvalidOperationException("Invalid session address");
        Snapshot map=Json.Deserialize<Snapshot>(File.ReadAllText(Path.Combine(Root,"native-session-targets.json")));
        if((DateTime.UtcNow-map.CreatedUtc.ToUniversalTime()).TotalSeconds>20)throw new InvalidOperationException("Session map is stale");
        Target t=map.Sessions.FirstOrDefault(s=>String.Equals(s.Provider,provider,StringComparison.OrdinalIgnoreCase)&&s.SessionId==id);
        if(t==null)throw new InvalidOperationException("Session has closed");
        uint owner; IntPtr hwnd=new IntPtr(t.Hwnd);
        if(!IsWindow(hwnd)||GetWindowThreadProcessId(hwnd,out owner)==0||owner!=(uint)t.Pid)throw new InvalidOperationException("Terminal no longer matches");
        using(Process agent=Process.GetProcessById(t.AgentPid)) {
            if(Math.Abs((agent.StartTime.ToUniversalTime()-t.AgentStarted.ToUniversalTime()).TotalSeconds)>1)throw new InvalidOperationException("Agent has changed");
        }
        return t;
    }
    static void Activate(string arguments) {
        try {
            ToastArguments a=ToastArguments.Parse(arguments);
            Target target=Resolve(a["provider"],a["session"]);
            Log("native click sid="+target.SessionId+" target="+target.Hwnd+" before="+GetForegroundWindow().ToInt64());
            Dispatcher.Invoke(new Action(delegate {
                try {
                    target=Resolve(target.Provider,target.SessionId);
                    IntPtr hwnd=new IntPtr(target.Hwnd);
                    if(IsIconic(hwnd))ShowWindowAsync(hwnd,9);
                    bool result=SetForegroundWindow(hwnd);
                    Log("direct focus sid="+target.SessionId+" result="+result+" foreground="+GetForegroundWindow().ToInt64());
                    if(!result&&GetForegroundWindow()!=hwnd)throw new InvalidOperationException("Windows did not allow switching to this session");
                    Timer observer=new Timer(); observer.Interval=2000;
                    observer.Tick+=delegate{observer.Stop();Log("retained sid="+target.SessionId+" target="+target.Hwnd+" foreground="+GetForegroundWindow().ToInt64());observer.Dispose();};
                    observer.Start();
                } catch(Exception e){Log("focus failed: "+e.Message);ShowError(e.Message);}
            }));
        } catch(Exception e){Log("activation rejected: "+e.Message);ShowError(e.Message);}
    }
    static void ReadQueue() {
        string queue=Path.Combine(Root,"native-toast-queue");
        if(!Directory.Exists(queue))return;
        foreach(string path in Directory.GetFiles(queue,"*.json")) {
            try {
                if(new FileInfo(path).Length>65536)continue;
                Request r=Json.Deserialize<Request>(File.ReadAllText(path));
                if(!Valid(r.Provider,r.SessionId)||(DateTime.UtcNow-r.CreatedUtc.ToUniversalTime()).TotalSeconds>120)continue;
                new ToastContentBuilder().AddArgument("provider",r.Provider).AddArgument("session",r.SessionId)
                    .AddText(r.Provider+" finished").AddText(r.Name+"\n"+r.Snippet)
                    .AddButton(new ToastButton().SetContent("Switch to session").AddArgument("provider",r.Provider).AddArgument("session",r.SessionId))
                    .AddAudio(new ToastAudio {Silent=true}).Show(delegate(Windows.UI.Notifications.ToastNotification toast){
                        toast.SuppressPopup=true; toast.Tag=r.SessionId; toast.Group=r.Provider;
                    });
                Log("history saved provider="+r.Provider+" sid="+r.SessionId);
            }catch(Exception e){Log("history failed: "+e.Message);}
            finally{try{File.Delete(path);}catch{}}
        }
    }
    [STAThread] static int Main(string[] args) {
        if(args.Length==3&&args[0]=="--validate")return Valid(args[1],args[2])?0:2;
        try {
            using(var mutex=new System.Threading.Mutex(false,"Local\\AgentNativeNotifications_MSA")) {
                if(!mutex.WaitOne(0))return 0;
                Dispatcher=new Form(); Dispatcher.ShowInTaskbar=false; Dispatcher.Opacity=0;
                IntPtr unused=Dispatcher.Handle;
                ToastNotificationManagerCompat.OnActivated+=delegate(ToastNotificationActivatedEventArgsCompat e){Activate(e.Argument);};
                Timer timer=new Timer();timer.Interval=300;timer.Tick+=delegate{ReadQueue();};timer.Start();
                File.WriteAllText(Path.Combine(Root,"native-toast-ready.json"),Json.Serialize(new {Pid=Process.GetCurrentProcess().Id}));
                Log("ready pid="+Process.GetCurrentProcess().Id);
                Application.Run();
                timer.Dispose();Dispatcher.Dispose();
                mutex.ReleaseMutex();
            }
            return 0;
        }catch(Exception e){Log("fatal: "+e);return 1;}
    }
}
