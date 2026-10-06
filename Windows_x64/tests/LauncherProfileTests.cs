static class LauncherProfileTests
{
    static async Task<int> Main(string[] args)
    {
        try
        {
            void Check(bool ok,string name)
            {
                if(!ok)throw new Exception("FAIL "+name);
                Console.WriteLine("PASS "+name);
            }
            var resources=Path.GetFullPath("Windows_x64/Resources");
            if(args.Contains("--all"))
            {
                await PageInstallerTests.Run(Path.GetFullPath("Windows_x64"),Check);
                await PageInstallerTests.RunLauncherProfiles(resources,args[0],Check);
                await PageInstallerTests.RunBundledProfiles(resources,args[0],Check);
                await ComponentReadTests.Run(resources);
            }
            else if(args.Contains("--agent"))await PageInstallerTests.RunBundledProfiles(resources,args[0],Check);
            else if(args.Contains("--components"))await ComponentReadTests.Run(resources);
            else await PageInstallerTests.RunLauncherProfiles(resources,args[0],Check);
            return 0;
        }
        catch(Exception error){Console.WriteLine(error);return 1;}
    }
}
