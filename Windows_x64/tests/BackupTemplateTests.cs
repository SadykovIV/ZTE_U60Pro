using System.Text;
using ZteImeiStudio.Windows.Core;

internal static class BackupTemplateTests
{
    public static void Run()
    {
        var stock=File.ReadAllText("Windows_x64/tests/fixtures/stock-usb-mode.synthetic.rc.local");
        void Check(bool ok,string name) { if(!ok)throw new Exception(name);Console.WriteLine("PASS "+name); }
        var expected=stock.Replace("#!/bin/sh\n","#!/bin/sh\n"+BackupPatch.EnableLine,StringComparison.Ordinal);
        var patched=BackupPatch.EnableAdb(Encoding.UTF8.GetBytes(stock));
        Check(Encoding.UTF8.GetString(patched)==expected,"Canonical stock block inserts exactly one prefix and preserves all remaining bytes");
        Check(BackupPatch.EnableAdb(patched).SequenceEqual(patched),"Canonical already-enabled archive is idempotent");
        var spaced=stock.Replace("if [", "\tif  [",StringComparison.Ordinal);
        Check(Encoding.UTF8.GetString(BackupPatch.EnableAdb(Encoding.UTF8.GetBytes(spaced)))==spaced.Replace("#!/bin/sh\n","#!/bin/sh\n"+BackupPatch.EnableLine,StringComparison.Ordinal),"Horizontal formatting preserves byte-exact source while validating the block");
        foreach(var body in new[] {
            "#!/bin/sh\n# /sys/class/android_usb/android0/usb_op\nexit 0\n",
            "#!/bin/sh\ncat /sys/class/android_usb/android0/usb_op\nexit 0\n",
            "#!/bin/sh\nexit 0\ncat /sys/class/android_usb/android0/usb_op\n",
            stock.Replace("#!/bin/sh\n","#!/bin/sh\nexit 0\n",StringComparison.Ordinal),
            stock.Replace("#!/bin/sh\n","#!/bin/sh\nnever_called() {\n",StringComparison.Ordinal)+"}\n",
            stock.Replace("#!/bin/sh\n","#!/bin/sh\ncat <<'EOF'\n",StringComparison.Ordinal)+"EOF\n",
            stock.Replace("cat /proc/driver/sensor_id","echo other",StringComparison.Ordinal),
            stock.Replace("#!/bin/sh\n","#!/bin/sh\nIGNORED=\"\n",StringComparison.Ordinal)+"\"\n",
            "#!/bin/sh\nprintf '/sys/class/android_usb/android0/usb_op\\n'\n",
            stock.Replace("fi\nelse","else",StringComparison.Ordinal),
            stock.Replace("\nif [ x", "\n\u00a0if [ x",StringComparison.Ordinal),
            stock.Replace("\nif [ x", "\n\fif [ x",StringComparison.Ordinal),
            stock.Replace("\nif [ x", "\n\rif [ x",StringComparison.Ordinal),
            "\u00a0# hidden non-ASCII token\n"+stock,
            stock+"echo 0 > "+BackupPatch.UsbNode+"\n",
            stock+"cat /sys/unknown/usb_op\n",
            stock.Replace("#!/bin/sh\n","#!/bin/sh\n# misplaced enable\n"+BackupPatch.EnableLine,StringComparison.Ordinal),
        })
        {
            try { BackupPatch.EnableAdb(Encoding.UTF8.GetBytes(body)); }
            catch(InvalidDataException) { Console.WriteLine("PASS Non-template USB reference cannot authorize restore"); continue; }
            throw new Exception("A USB path alone must not authorize backup restore");
        }
    }
}
