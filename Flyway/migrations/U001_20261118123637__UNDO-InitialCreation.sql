SET NUMERIC_ROUNDABORT OFF
GO
SET ANSI_PADDING, ANSI_WARNINGS, CONCAT_NULL_YIELDS_NULL, ARITHABORT, QUOTED_IDENTIFIER, ANSI_NULLS ON
GO
PRINT N'Dropping constraints from [dbo].[Products]'
GO
ALTER TABLE [dbo].[Products] DROP CONSTRAINT [PK_Products]
GO
PRINT N'Dropping constraints from [dbo].[__EFMigrationsHistory]'
GO
ALTER TABLE [dbo].[__EFMigrationsHistory] DROP CONSTRAINT [PK___EFMigrationsHistory]
GO
PRINT N'Dropping constraints from [dbo].[Products]'
GO
ALTER TABLE [dbo].[Products] DROP CONSTRAINT [DF__Products__Price__398D8EEE]
GO
PRINT N'Dropping [dbo].[__EFMigrationsHistory]'
GO
DROP TABLE [dbo].[__EFMigrationsHistory]
GO
PRINT N'Dropping [dbo].[Products]'
GO
DROP TABLE [dbo].[Products]
GO

