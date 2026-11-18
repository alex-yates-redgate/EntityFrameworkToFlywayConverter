SET NUMERIC_ROUNDABORT OFF
GO
SET ANSI_PADDING, ANSI_WARNINGS, CONCAT_NULL_YIELDS_NULL, ARITHABORT, QUOTED_IDENTIFIER, ANSI_NULLS ON
GO
PRINT N'Creating [dbo].[Products]'
GO
CREATE TABLE [dbo].[Products]
(
[Id] [int] NOT NULL IDENTITY(1, 1),
[Name] [nvarchar] (100) NOT NULL,
[Price] [decimal] (18, 2) NOT NULL CONSTRAINT [DF__Products__Price__398D8EEE] DEFAULT ((0.0))
)
GO
PRINT N'Creating primary key [PK_Products] on [dbo].[Products]'
GO
ALTER TABLE [dbo].[Products] ADD CONSTRAINT [PK_Products] PRIMARY KEY CLUSTERED ([Id])
GO
PRINT N'Creating [dbo].[__EFMigrationsHistory]'
GO
CREATE TABLE [dbo].[__EFMigrationsHistory]
(
[MigrationId] [nvarchar] (150) NOT NULL,
[ProductVersion] [nvarchar] (32) NOT NULL
)
GO
PRINT N'Creating primary key [PK___EFMigrationsHistory] on [dbo].[__EFMigrationsHistory]'
GO
ALTER TABLE [dbo].[__EFMigrationsHistory] ADD CONSTRAINT [PK___EFMigrationsHistory] PRIMARY KEY CLUSTERED ([MigrationId])
GO

