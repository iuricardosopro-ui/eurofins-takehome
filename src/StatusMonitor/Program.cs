using StatusMonitor;

var builder = Host.CreateApplicationBuilder(args);

// When installed as a Windows Service, talk to the Service Control Manager (start/stop)
builder.Services.AddWindowsService(options => options.ServiceName = "StatusMonitor");

builder.Services.AddHostedService<Worker>();

var host = builder.Build();
host.Run();
