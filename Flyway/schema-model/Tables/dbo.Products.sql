CREATE TABLE [dbo].[Products]
(
[Id] [int] NOT NULL IDENTITY(1, 1),
[Name] [nvarchar] (100) NOT NULL,
[Price] [decimal] (18, 2) NOT NULL CONSTRAINT [DF__Products__Price__398D8EEE] DEFAULT ((0.0))
)
GO
ALTER TABLE [dbo].[Products] ADD CONSTRAINT [PK_Products] PRIMARY KEY CLUSTERED ([Id])
GO
