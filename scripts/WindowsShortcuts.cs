using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

namespace ServerKilnSetup
{
    // IShellLinkW avoids the ANSI path conversion performed by WScript.Shell on some hosts.
    public static class Shortcuts
    {
        public static void Create(string file, string target, string directory)
        {
            IShellLinkW link = (IShellLinkW)new ShellLink();
            try
            {
                link.SetPath(target);
                link.SetWorkingDirectory(directory);
                link.SetArguments("");
                link.SetDescription("ServerKiln GPU server monitor");
                link.SetIconLocation(target, 0);
                ((IPersistFile)link).Save(file, true);
            }
            finally { Marshal.FinalReleaseComObject(link); }
        }

        public static ShortcutInfo Inspect(string file)
        {
            IShellLinkW link = (IShellLinkW)new ShellLink();
            try
            {
                ((IPersistFile)link).Load(file, 0);
                StringBuilder target = new StringBuilder(32768);
                StringBuilder directory = new StringBuilder(32768);
                StringBuilder arguments = new StringBuilder(4096);
                link.GetPath(target, target.Capacity, IntPtr.Zero, 4);
                link.GetWorkingDirectory(directory, directory.Capacity);
                link.GetArguments(arguments, arguments.Capacity);
                return new ShortcutInfo { TargetPath = target.ToString(), WorkingDirectory = directory.ToString(), Arguments = arguments.ToString() };
            }
            finally { Marshal.FinalReleaseComObject(link); }
        }

        [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
        private class ShellLink { }

        [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IShellLinkW
        {
            void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int count, IntPtr data, uint flags);
            void GetIDList(out IntPtr idList);
            void SetIDList(IntPtr idList);
            void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder description, int count);
            void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string description);
            void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder directory, int count);
            void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string directory);
            void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder arguments, int count);
            void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string arguments);
            void GetHotkey(out short hotkey);
            void SetHotkey(short hotkey);
            void GetShowCmd(out int command);
            void SetShowCmd(int command);
            void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder icon, int count, out int index);
            void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string icon, int index);
            void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, uint reserved);
            void Resolve(IntPtr window, uint flags);
            void SetPath([MarshalAs(UnmanagedType.LPWStr)] string path);
        }
    }

    public sealed class ShortcutInfo
    {
        public string TargetPath { get; set; }
        public string WorkingDirectory { get; set; }
        public string Arguments { get; set; }
    }
}
