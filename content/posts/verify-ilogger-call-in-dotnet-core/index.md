---
title:  "Verify ILogger call in .NET Core"
description:  "Advantages of using handwritten mock for ILogger in .NET Core"
date: 2020-02-08
draft: false
cover: /images/card-default-cover.png
tags:
- programming
- net-core
- unit-testing
categories:
- programming
---

## Problem

In my current project (.NET Core backend), there have been a few times I find myself in the situation of writing tests to verify whether `ILogger.Log()` method is called with some expected values. Most of the time I find this kind of test brittle (since a slight change in log message can cause the tests to be broken) and not providing any actual values.

There are still some exceptional cases when the log message provides some important information that you want to make sure it's always there. In those cases, most people will just rely on mocking framework (.e.q. Moq). In this post I will explain why I find that approach difficult to use and introduce an alternative approach.

## Sample Application

To demonstrate the problem, I just modified the weather forecast sample .NET Core Web API project as follow:

``` csharp
public class WeatherForecastController : ControllerBase
{
    private readonly ITellDateTime _dateTimeProvider;
    private readonly ILogger<WeatherForecastController> _logger;
    private readonly IWeatherClient _weatherClient;

    public WeatherForecastController(ITellDateTime dateTimeProvider, ILogger<WeatherForecastController> logger,
        IWeatherClient weatherClient)
    {
        _dateTimeProvider = dateTimeProvider;
        _logger = logger;
        _weatherClient = weatherClient;
    }

    [HttpGet]
    public IEnumerable<WeatherForecast> Get()
    {
        var now = _dateTimeProvider.CurrentTime();
        return Enumerable.Range(1, 5).Select(index =>
            {
                var date = now.AddDays(index);
                try
                {
                    var temp = _weatherClient.GetTemperature(date);
                    return new WeatherForecast(date, temp);
                }
                catch (Exception e)
                {
                    _logger.LogError(e, $"failed to get weather for date {date:dd/MM/yyyy}");
                    return new WeatherForecast(date);
                }
            })
            .ToArray();
    }
}
```

The behavior of `Get()` method is slightly different from the sample provided by .NET Core: it now invokes `GetTemperature()` from an instance of `IWeatherClient` to get temperature for a specific date. And if there's anything wrong when getting temperature from weather client, it just logs the error and continue with the next day.

`ITellDateTime` is just an interface to wrap around .NET `DateTime` so that we can deterministically stub it in tests.

This is the implementation of `InMemoryWeatherClient` if you are interested. This class is not our main concern in this post.

``` csharp
public class InMemoryWeatherClient : IWeatherClient
{
    private readonly Random _random;

    public InMemoryWeatherClient()
    {
        _random = new Random();
    }

    public int GetTemperature(DateTime date)
    {
        return _random.Next(-20, 55);
    }
}
```

## Using Moq to verify ILogger call

Since the application can fail when getting temperature for any day, we probably want to write a test to make sure that the application logs the specific date when it fails to get the temperature. The test will look something like this when using Moq:

``` csharp
[Fact]
public void Get_WithMoq_WhenWeatherClientThrowsException_ShouldLogErrorWithFailedInput()
{
    var mockLogger = new Mock<ILogger<WeatherForecastController>>();

    var current = new DateTime(2020, 1, 15, 0, 0, 0);
    var mockDateTimeProvider = MockDateTimeProvider(current);

    var exception = new Exception("some exception");
    var dayCausingException = 17;
    var mockClient = MockClientThrowingException(exception, dayCausingException);

    var controller = new WeatherForecastController(mockDateTimeProvider.Object, mockLogger.Object, mockClient.Object);

    controller.Get();

    mockLogger.Verify(l =>
        l.Log(
            LogLevel.Error,
            It.IsAny<EventId>(),
            It.Is<It.IsAnyType>((state, type) => state.ToString().Contains("date 17/01/2020")),
            exception,
            (Func<object, Exception, string>)It.IsAny<object>()
            ));

}
```

and some helper methods to stub dependencies:

``` csharp
private static Mock<ITellDateTime> MockDateTimeProvider(DateTime current)
{
    var mockDateTimeProvider = new Mock<ITellDateTime>();
    mockDateTimeProvider = new Mock<ITellDateTime>();
    mockDateTimeProvider.Setup(p => p.CurrentTime()).Returns(current);
    return mockDateTimeProvider;
}

private static Mock<IWeatherClient> MockClientThrowingException(Exception exception, int onDay = 17)
{
    var failedDate = new DateTime(2020, 1, onDay, 0, 0, 0);
    var mockClient = new Mock<IWeatherClient>();
    mockClient.Setup(c => c.GetTemperature(It.IsNotIn(failedDate))).Returns(3);
    mockClient.Setup(c => c.GetTemperature(failedDate))
        .Throws(exception);
    return mockClient;
}
```

you might say: "it doesn't look so bad. What's the problem with this?"

The problem is: in order to come up with correct `Verify()` call, I needed to trace through 4 extension methods in .NET Core source code to know what is the correct parameters that I should expect. The reason I need to do this is because the application is using `ILogger.LogError()`. This method is an extension method to `ILogger` and therefore a static method, which Moq is not able to mock/verify. This also makes the test misleading because it verifies `Log()` method which is not visible anywhere in actual implementation.

Second problem is that it's difficult to provide correct values to `Verify()` call. Although I know the expected types that `Log()` method expects after tracing through 4 extension methods, I'm only able to make the test pass after several trial-and-error and countless google searches. To make things worse, when I provided incorrect parameter to the `Verify()` method, the error message when running tests didn't provide anything meaningful (`Expected invocation on the mock at least once, but was never performed`). I was not able to guess what parameter was provided incorrectly from that error message.

## Using handwritten mock

To solve the problem above, I use a handwritten implementation of `ILogger` that keeps log message/error in in-memory for verification:

``` csharp
public class InMemoryFakeLogger<T> : ILogger<T>
{
    public LogLevel Level { get; private set; }
    public Exception Ex { get; private set; }
    public string Message { get; private set; }

    public IDisposable BeginScope<TState>(TState state)
    {
        return NullScope.Instance;
    }

    public bool IsEnabled(LogLevel logLevel)
    {
        return true;
    }

    public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception exception, Func<TState, Exception, string> formatter)
    {
        Level = logLevel;
        Message = state.ToString();
        Ex = exception;
    }

    /// <summary>
    /// Reference: https://github.com/aspnet/Logging/blob/master/src/Microsoft.Extensions.Logging.Abstractions/Internal/NullScope.cs
    /// </summary>
    public class NullScope : IDisposable
    {
        public static NullScope Instance { get; } = new NullScope();

        private NullScope()
        {
        }

        public void Dispose()
        {
        }
    }
}
```

To use this in-memory logger in tests:

``` csharp
[Fact]
public void Get_WhenWeatherClientThrowsException_ShouldLogErrorWithFailedInput()
{
    var logger = new InMemoryFakeLogger<WeatherForecastController>();

    var current = new DateTime(2020, 1, 15, 0, 0, 0);
    var mockDateTimeProvider = MockDateTimeProvider(current);

    var exception = new Exception("some exception");
    var dayCausingException = 17;
    var mockClient = MockClientThrowingException(exception, dayCausingException);

    var controller = new WeatherForecastController(mockDateTimeProvider.Object, logger, mockClient.Object);

    controller.Get();

    Assert.Contains("date 17/01/2020", logger.Message);
    Assert.StrictEqual(exception, logger.Ex);
}
```

As you can see, instead of verifying whether the `Log()` method is called with correct parameters, now I just need to assert whether the recorded message/exception in the logger are correct. The test is much simpler and easier to understand.

This technique is not new, pretty trivial to implement but the result is quite pleasant. All I did is to convert communication-based testing to state-based testing (.i.e. instead of verifying communication among dependencies, I verify state of dependency instead).
