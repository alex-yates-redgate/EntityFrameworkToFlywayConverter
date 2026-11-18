using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Design;

namespace EntityFramework.Data;

public class AppDbContextFactory : IDesignTimeDbContextFactory<AppDbContext>
{
    public AppDbContext CreateDbContext(string[] args)
    {
        var password = Environment.GetEnvironmentVariable("MSSQL_SA_PASSWORD")
            ?? throw new InvalidOperationException("Set MSSQL_SA_PASSWORD before using EF tooling.");
        var port = Environment.GetEnvironmentVariable("MSSQL_PORT") ?? "1433";
        var database = Environment.GetEnvironmentVariable("MSSQL_DATABASE_NAME") ?? "EntityFrameworkDemo";
        var connectionString = new SqlConnectionStringBuilder
        {
            DataSource = $"localhost,{port}",
            InitialCatalog = database,
            UserID = "sa",
            Password = password,
            TrustServerCertificate = true
        }.ConnectionString;

        var options = new DbContextOptionsBuilder<AppDbContext>()
            .UseSqlServer(connectionString)
            .Options;

        return new AppDbContext(options);
    }
}
