# Build stage: compile and publish with the .NET 10 SDK
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

# Restore first (cached layer), then copy the source
COPY Directory.Build.props ./
COPY src/HelloWorld/HelloWorld.csproj src/HelloWorld/
RUN dotnet restore src/HelloWorld/HelloWorld.csproj
COPY src/HelloWorld/ src/HelloWorld/
RUN dotnet publish src/HelloWorld/HelloWorld.csproj -c Release -o /app --no-restore -p:UseAppHost=false

# Runtime stage: only the ASP.NET Core runtime, running as the non-root "app" user
FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app
COPY --from=build /app .
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["dotnet", "HelloWorld.dll"]
