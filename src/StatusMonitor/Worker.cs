namespace StatusMonitor;

public class Worker(ILogger<Worker> logger, IConfiguration configuration) : BackgroundService
{
    // One HttpClient for the whole life of the service, with an explicit timeout
    private readonly HttpClient _httpClient = new() { Timeout = TimeSpan.FromSeconds(10) };

    // Log file in the same folder as the executable (assignment requirement)
    private readonly string _logFile = Path.Combine(AppContext.BaseDirectory, "status.log");

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        // Settings come from appsettings.json, not hard-coded
        var url = configuration["StatusMonitor:Url"]
            ?? throw new InvalidOperationException("Missing setting StatusMonitor:Url");
        var interval = TimeSpan.FromSeconds(configuration.GetValue("StatusMonitor:IntervalSeconds", 60));
        logger.LogInformation("Checking {Url} every {Interval}, logging to {LogFile}", url, interval, _logFile);

        // First check runs immediately, then once per interval
        using var timer = new PeriodicTimer(interval);
        do
        {
            var (code, message) = await CheckAsync(url, stoppingToken);
            var line = $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss zzz} {url} {code} {message}";
            await File.AppendAllTextAsync(_logFile, line + Environment.NewLine, stoppingToken);
            logger.LogInformation("{Line}", line);
            if (code != 200)
            {
                // Assignment: stop when the status is not 200 OK.
                // Exit the process with code 1 (failure). A clean stop would look like
                // a normal shutdown to Windows and the recovery action (Step 4) would not run.
                logger.LogError("Status {Code} is not 200, stopping the service", code);
                Environment.Exit(1);
            }
        }
        while (await timer.WaitForNextTickAsync(stoppingToken));
    }

    private async Task<(int Code, string Message)> CheckAsync(string url, CancellationToken stoppingToken)
    {
        try
        {
            using var response = await _httpClient.GetAsync(url, stoppingToken);
            return ((int)response.StatusCode, response.ReasonPhrase ?? string.Empty);
        }
        catch (HttpRequestException ex)
        {
            // Site down / connection refused: there is no HTTP code, so we log 0
            return (0, $"Connection error: {ex.Message}");
        }
        catch (TaskCanceledException) when (!stoppingToken.IsCancellationRequested)
        {
            // The request took longer than the HttpClient timeout
            return (0, "Timeout");
        }
    }
}
