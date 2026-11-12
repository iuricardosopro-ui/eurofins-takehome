namespace StatusMonitor;

public class Worker(ILogger<Worker> logger, IConfiguration configuration) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        // Settings come from appsettings.json, not hard-coded
        var url = configuration["StatusMonitor:Url"]
            ?? throw new InvalidOperationException("Missing setting StatusMonitor:Url");
        var interval = TimeSpan.FromSeconds(configuration.GetValue("StatusMonitor:IntervalSeconds", 60));
        logger.LogInformation("Checking {Url} every {Interval}", url, interval);

        // First check runs immediately, then once per interval
        using var timer = new PeriodicTimer(interval);
        do
        {
            logger.LogInformation("Check at {Time}", DateTimeOffset.Now);
        }
        while (await timer.WaitForNextTickAsync(stoppingToken));
    }
}
