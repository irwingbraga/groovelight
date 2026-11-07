using System.IO.Pipes;
using System.Text;
using System.Text.Json;

namespace Groovelight.ControlKit;

/// <summary>Sends requests to the running app: one request and one reply per connection, each a line of JSON.</summary>
public static class ControlClient
{
    /// <summary>Whether the app is listening (it answers a status request).</summary>
    public static bool IsAvailable(string? pipe = null)
    {
        try
        {
            Send(new StatusRequest(), pipe, TimeSpan.FromSeconds(2));
            return true;
        }
        catch (ControlException)
        {
            return false;
        }
    }

    public static ControlReply Send(ControlRequest request, string? pipe = null, TimeSpan? timeout = null)
    {
        var limit = timeout ?? TimeSpan.FromSeconds(30);
        using var client = new NamedPipeClientStream(".", pipe ?? ControlPipe.Name(), PipeDirection.InOut, PipeOptions.CurrentUserOnly);
        try
        {
            client.Connect((int)Math.Min(limit.TotalMilliseconds, 2000));
        }
        catch (Exception error) when (error is TimeoutException or IOException or UnauthorizedAccessException or ArgumentException)
        {
            throw new ControlException("Groovelight is not running.");
        }
        try
        {
            var body = JsonSerializer.Serialize(new Envelope(ControlPipe.ProtocolVersion, request), ControlPipe.Json);
            var writer = new StreamWriter(client, new UTF8Encoding(false), leaveOpen: true) { AutoFlush = true };
            writer.Write(body + "\n");
            var reading = new StreamReader(client, Encoding.UTF8, leaveOpen: true).ReadLineAsync();
            if (!reading.Wait(limit))
                throw new ControlException("Groovelight did not answer in time. It may be showing a dialog: answer it and try again.");
            var line = reading.Result ?? throw new ControlException("Groovelight closed the connection without answering.");
            return JsonSerializer.Deserialize<ControlReply>(line, ControlPipe.Json)
                ?? throw new ControlException("Groovelight sent a reply this tool cannot read. Update the app and the tool together.");
        }
        catch (JsonException)
        {
            throw new ControlException("Groovelight sent a reply this tool cannot read. Update the app and the tool together.");
        }
        catch (AggregateException error) when (error.InnerException is IOException)
        {
            throw new ControlException("Lost the connection to Groovelight.");
        }
        catch (IOException)
        {
            throw new ControlException("Lost the connection to Groovelight.");
        }
    }

    /// <summary>Sends a request and, when it starts a job, polls it until it is done, passing every update along.</summary>
    public static ControlReply Run(ControlRequest request, Action<ControlReply>? onUpdate = null, string? pipe = null, TimeSpan? interval = null)
    {
        var reply = Send(request, pipe);
        while (reply is { Job: { } job, Finished: false, Error: null })
        {
            onUpdate?.Invoke(reply);
            Thread.Sleep(interval ?? TimeSpan.FromMilliseconds(250));
            reply = Send(new PollRequest(job), pipe);
        }
        return reply;
    }
}

/// <summary>The app's end: answers each request with <c>handler</c> (which the app runs on its UI thread).</summary>
public sealed class ControlServer(Func<ControlRequest, Task<ControlReply>> handler) : IDisposable
{
    private readonly CancellationTokenSource stopping = new();
    private string? name;

    /// <summary>Starts listening; false when the name is taken (another copy of the app answers it).</summary>
    public bool Start(string? pipe = null)
    {
        name = pipe ?? ControlPipe.Name();
        NamedPipeServerStream first;
        try
        {
            first = Create(name, PipeOptions.FirstPipeInstance);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return false;
        }
        _ = Task.Run(() => ListenAsync(first));
        return true;
    }

    private static NamedPipeServerStream Create(string name, PipeOptions extra = PipeOptions.None) =>
        new(name, PipeDirection.InOut, NamedPipeServerStream.MaxAllowedServerInstances, PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly | extra);

    private async Task ListenAsync(NamedPipeServerStream server)
    {
        while (!stopping.IsCancellationRequested)
        {
            try
            {
                await server.WaitForConnectionAsync(stopping.Token);
            }
            catch (Exception error) when (error is OperationCanceledException or IOException or ObjectDisposedException)
            {
                await server.DisposeAsync();
                if (stopping.IsCancellationRequested) return;
                server = Create(name!);
                continue;
            }
            var connected = server;
            _ = Task.Run(() => AnswerAsync(connected));
            try
            {
                server = Create(name!);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                return;
            }
        }
        await server.DisposeAsync();
    }

    private async Task AnswerAsync(NamedPipeServerStream connection)
    {
        await using (connection)
        {
            try
            {
                var line = await new StreamReader(connection, Encoding.UTF8, leaveOpen: true).ReadLineAsync(stopping.Token);
                var reply = await AnswerAsync(line);
                var writer = new StreamWriter(connection, new UTF8Encoding(false), leaveOpen: true) { AutoFlush = true };
                await writer.WriteAsync(JsonSerializer.Serialize(reply, ControlPipe.Json) + "\n");
                if (OperatingSystem.IsWindows()) connection.WaitForPipeDrain();
            }
            catch (Exception error) when (error is IOException or OperationCanceledException or ObjectDisposedException)
            {
            }
        }
    }

    /// <summary>The reply to one line of a client.</summary>
    internal async Task<ControlReply> AnswerAsync(string? line)
    {
        Envelope? envelope;
        try
        {
            envelope = line is null ? null : JsonSerializer.Deserialize<Envelope>(line, ControlPipe.Json);
        }
        catch (JsonException)
        {
            envelope = null;
        }
        if (envelope?.Request is null) return ControlReply.Failure("Groovelight could not read the request. Update the app and the tool together.");
        if (envelope.Version != ControlPipe.ProtocolVersion)
            return ControlReply.Failure($"This tool speaks version {envelope.Version} of the protocol, the app version {ControlPipe.ProtocolVersion}. Use the tool that comes with the app.");
        try
        {
            return await handler(envelope.Request);
        }
        catch (ControlException error)
        {
            return ControlReply.Failure(error.Message);
        }
    }

    public void Dispose() => stopping.Cancel();
}
