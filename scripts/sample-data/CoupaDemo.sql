/*
    Coupa demo - Business Spend Management (procure-to-pay) sample data.

    Creates three databases with fictional data (Microsoft sample company names):
      CoupaProcurement : cost centers, employees, commodities, suppliers, contracts,
                         catalog items, requisitions, approvals, purchase orders
      CoupaInvoicing   : supplier invoices, invoice lines, payments
      CoupaExpenses    : expense categories (policy), expense reports, expense lines

    Dates are generated relative to the day the script runs (last ~12 months).
    Idempotent: objects are created only if missing and data is seeded only into
    empty tables. Run on the AG primary (or any standalone instance) from SSMS,
    or via scripts\sample-data\New-CoupaDemoDatabases.ps1.
*/
SET NOCOUNT ON;
GO

IF DB_ID(N'CoupaProcurement') IS NULL CREATE DATABASE CoupaProcurement;
GO
IF DB_ID(N'CoupaInvoicing') IS NULL CREATE DATABASE CoupaInvoicing;
GO
IF DB_ID(N'CoupaExpenses') IS NULL CREATE DATABASE CoupaExpenses;
GO
-- Availability groups require the FULL recovery model.
DECLARE @db sysname, @sql nvarchar(400);
DECLARE dbs CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases
    WHERE name IN (N'CoupaProcurement', N'CoupaInvoicing', N'CoupaExpenses') AND recovery_model_desc <> 'FULL';
OPEN dbs;
FETCH NEXT FROM dbs INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'ALTER DATABASE ' + QUOTENAME(@db) + N' SET RECOVERY FULL;';
    EXEC (@sql);
    FETCH NEXT FROM dbs INTO @db;
END
CLOSE dbs; DEALLOCATE dbs;
GO
-- Row versioning for readers so reports don't block (or get blocked by) OLTP writers.
DECLARE @db sysname, @sql nvarchar(400);
DECLARE dbs CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases
    WHERE name IN (N'CoupaProcurement', N'CoupaInvoicing', N'CoupaExpenses') AND is_read_committed_snapshot_on = 0;
OPEN dbs;
FETCH NEXT FROM dbs INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'ALTER DATABASE ' + QUOTENAME(@db) + N' SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;';
    EXEC (@sql);
    FETCH NEXT FROM dbs INTO @db;
END
CLOSE dbs; DEALLOCATE dbs;
GO

/* =====================================================================
   CoupaProcurement
   ===================================================================== */
USE CoupaProcurement;
GO

IF OBJECT_ID(N'dbo.CostCenters') IS NULL
CREATE TABLE dbo.CostCenters (
    CostCenterId   int            NOT NULL PRIMARY KEY,
    CostCenterCode varchar(10)    NOT NULL UNIQUE,
    Name           nvarchar(60)   NOT NULL,
    Region         nvarchar(30)   NOT NULL,
    AnnualBudget   decimal(14,2)  NOT NULL
);

IF OBJECT_ID(N'dbo.Employees') IS NULL
CREATE TABLE dbo.Employees (
    EmployeeId     int            NOT NULL PRIMARY KEY,
    FullName       nvarchar(80)   NOT NULL,
    Email          varchar(120)   NOT NULL UNIQUE,
    JobTitle       nvarchar(60)   NOT NULL,
    CostCenterId   int            NOT NULL REFERENCES dbo.CostCenters (CostCenterId),
    ManagerId      int            NULL REFERENCES dbo.Employees (EmployeeId),
    ApprovalLimit  decimal(14,2)  NOT NULL
);

IF OBJECT_ID(N'dbo.Commodities') IS NULL
CREATE TABLE dbo.Commodities (
    CommodityId    int            NOT NULL PRIMARY KEY,
    Name           nvarchar(60)   NOT NULL,
    UNSPSCSegment  char(8)        NOT NULL
);

IF OBJECT_ID(N'dbo.Suppliers') IS NULL
CREATE TABLE dbo.Suppliers (
    SupplierId         int            NOT NULL PRIMARY KEY,
    SupplierNumber     varchar(12)    NOT NULL UNIQUE,
    SupplierName       nvarchar(120)  NOT NULL,
    PrimaryCommodityId int            NOT NULL REFERENCES dbo.Commodities (CommodityId),
    Country            char(2)        NOT NULL,
    PaymentTerms       varchar(10)    NOT NULL,
    RiskRating         varchar(10)    NOT NULL CHECK (RiskRating IN ('Low', 'Medium', 'High')),
    IsDiverseSupplier  bit            NOT NULL,
    Status             varchar(12)    NOT NULL CHECK (Status IN ('Active', 'On Hold', 'Onboarding')),
    OnboardedDate      date           NOT NULL
);

IF OBJECT_ID(N'dbo.Contracts') IS NULL
CREATE TABLE dbo.Contracts (
    ContractId     int IDENTITY   NOT NULL PRIMARY KEY,
    ContractNumber varchar(20)    NOT NULL UNIQUE,
    SupplierId     int            NOT NULL REFERENCES dbo.Suppliers (SupplierId),
    Title          nvarchar(160)  NOT NULL,
    StartDate      date           NOT NULL,
    EndDate        date           NOT NULL,
    ContractValue  decimal(14,2)  NOT NULL,
    Currency       char(3)        NOT NULL,
    AutoRenew      bit            NOT NULL,
    OwnerId        int            NOT NULL REFERENCES dbo.Employees (EmployeeId)
);

IF OBJECT_ID(N'dbo.CatalogItems') IS NULL
CREATE TABLE dbo.CatalogItems (
    ItemId         int            NOT NULL PRIMARY KEY,
    SupplierId     int            NOT NULL REFERENCES dbo.Suppliers (SupplierId),
    CommodityId    int            NOT NULL REFERENCES dbo.Commodities (CommodityId),
    ItemName       nvarchar(120)  NOT NULL,
    UnitOfMeasure  varchar(10)    NOT NULL,
    UnitPrice      decimal(12,2)  NOT NULL
);

IF OBJECT_ID(N'dbo.Requisitions') IS NULL
CREATE TABLE dbo.Requisitions (
    RequisitionId  int IDENTITY   NOT NULL PRIMARY KEY,
    ReqNumber      varchar(20)    NOT NULL UNIQUE,
    RequesterId    int            NOT NULL REFERENCES dbo.Employees (EmployeeId),
    CostCenterId   int            NOT NULL REFERENCES dbo.CostCenters (CostCenterId),
    Status         varchar(20)    NOT NULL,
    SubmittedAt    datetime2(0)   NOT NULL,
    NeedByDate     date           NOT NULL,
    Justification  nvarchar(200)  NOT NULL
);

IF OBJECT_ID(N'dbo.RequisitionLines') IS NULL
CREATE TABLE dbo.RequisitionLines (
    RequisitionLineId int IDENTITY NOT NULL PRIMARY KEY,
    RequisitionId  int            NOT NULL REFERENCES dbo.Requisitions (RequisitionId),
    LineNumber     smallint       NOT NULL,
    ItemId         int            NOT NULL REFERENCES dbo.CatalogItems (ItemId),
    Quantity       decimal(10,2)  NOT NULL,
    UnitPrice      decimal(12,2)  NOT NULL,
    LineTotal      AS (CAST(Quantity * UnitPrice AS decimal(14,2))) PERSISTED,
    CONSTRAINT UQ_RequisitionLines UNIQUE (RequisitionId, LineNumber)
);

IF OBJECT_ID(N'dbo.Approvals') IS NULL
CREATE TABLE dbo.Approvals (
    ApprovalId     int IDENTITY   NOT NULL PRIMARY KEY,
    RequisitionId  int            NOT NULL REFERENCES dbo.Requisitions (RequisitionId),
    ApproverId     int            NOT NULL REFERENCES dbo.Employees (EmployeeId),
    ApprovalStep   tinyint        NOT NULL,
    Decision       varchar(12)    NOT NULL CHECK (Decision IN ('Approved', 'Rejected', 'Pending')),
    DecidedAt      datetime2(0)   NULL,
    Comments       nvarchar(200)  NULL
);

IF OBJECT_ID(N'dbo.PurchaseOrders') IS NULL
CREATE TABLE dbo.PurchaseOrders (
    PurchaseOrderId int IDENTITY  NOT NULL PRIMARY KEY,
    PONumber       varchar(20)    NOT NULL UNIQUE,
    RequisitionId  int            NOT NULL REFERENCES dbo.Requisitions (RequisitionId),
    SupplierId     int            NOT NULL REFERENCES dbo.Suppliers (SupplierId),
    Status         varchar(20)    NOT NULL,
    OrderDate      date           NOT NULL,
    Currency       char(3)        NOT NULL,
    ShipToSite     nvarchar(60)   NOT NULL
);

IF OBJECT_ID(N'dbo.PurchaseOrderLines') IS NULL
CREATE TABLE dbo.PurchaseOrderLines (
    PurchaseOrderLineId int IDENTITY NOT NULL PRIMARY KEY,
    PurchaseOrderId int           NOT NULL REFERENCES dbo.PurchaseOrders (PurchaseOrderId),
    LineNumber     smallint       NOT NULL,
    ItemId         int            NOT NULL REFERENCES dbo.CatalogItems (ItemId),
    Quantity       decimal(10,2)  NOT NULL,
    QuantityReceived decimal(10,2) NOT NULL,
    UnitPrice      decimal(12,2)  NOT NULL,
    LineTotal      AS (CAST(Quantity * UnitPrice AS decimal(14,2))) PERSISTED
);
GO

-- Foreign-key and lookup indexes (idempotent, so rerunning this script adds them to existing databases).
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Requisitions_Requester') CREATE INDEX IX_Requisitions_Requester ON dbo.Requisitions (RequesterId);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Requisitions_Status') CREATE INDEX IX_Requisitions_Status ON dbo.Requisitions (Status);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Approvals_Requisition') CREATE INDEX IX_Approvals_Requisition ON dbo.Approvals (RequisitionId);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Approvals_Approver') CREATE INDEX IX_Approvals_Approver ON dbo.Approvals (ApproverId, Decision);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_PurchaseOrders_Requisition') CREATE INDEX IX_PurchaseOrders_Requisition ON dbo.PurchaseOrders (RequisitionId);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_PurchaseOrders_Supplier') CREATE INDEX IX_PurchaseOrders_Supplier ON dbo.PurchaseOrders (SupplierId);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_PurchaseOrders_Status') CREATE INDEX IX_PurchaseOrders_Status ON dbo.PurchaseOrders (Status);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_PurchaseOrderLines_PO') CREATE INDEX IX_PurchaseOrderLines_PO ON dbo.PurchaseOrderLines (PurchaseOrderId);
GO

IF EXISTS (SELECT 1 FROM dbo.Suppliers) RETURN;

BEGIN TRANSACTION;

INSERT dbo.CostCenters (CostCenterId, CostCenterCode, Name, Region, AnnualBudget) VALUES
 (1, 'CC-1000', N'Finance',                N'North America', 1200000),
 (2, 'CC-2000', N'Information Technology', N'North America', 4800000),
 (3, 'CC-3000', N'Marketing',              N'EMEA',          2500000),
 (4, 'CC-4000', N'Sales',                  N'North America', 3100000),
 (5, 'CC-5000', N'Human Resources',        N'North America',  900000),
 (6, 'CC-6000', N'Operations',             N'APAC',          3600000),
 (7, 'CC-7000', N'Legal',                  N'EMEA',           750000),
 (8, 'CC-8000', N'Research & Development', N'North America', 5200000);

INSERT dbo.Employees (EmployeeId, FullName, Email, JobTitle, CostCenterId, ManagerId, ApprovalLimit) VALUES
 ( 1, N'Olivia Bennett',  'olivia.bennett@contoso.com',  N'Chief Financial Officer',     1, NULL, 1000000),
 ( 2, N'Marcus Chen',     'marcus.chen@contoso.com',     N'VP Procurement',              1,  1,   250000),
 ( 3, N'Priya Raman',     'priya.raman@contoso.com',     N'CIO',                         2,  1,   500000),
 ( 4, N'Daniel Okafor',   'daniel.okafor@contoso.com',   N'VP Marketing',                3,  1,   150000),
 ( 5, N'Sofia Alvarez',   'sofia.alvarez@contoso.com',   N'VP Sales',                    4,  1,   150000),
 ( 6, N'Grace Kim',       'grace.kim@contoso.com',       N'HR Director',                 5,  1,    75000),
 ( 7, N'Liam O''Connor',  'liam.oconnor@contoso.com',    N'COO',                         6,  1,   500000),
 ( 8, N'Hannah Weiss',    'hannah.weiss@contoso.com',    N'General Counsel',             7,  1,   100000),
 ( 9, N'Arjun Mehta',     'arjun.mehta@contoso.com',     N'VP Engineering',              8,  1,   300000),
 (10, N'Emily Carter',    'emily.carter@contoso.com',    N'Procurement Manager',         1,  2,    50000),
 (11, N'Noah Fischer',    'noah.fischer@contoso.com',    N'IT Infrastructure Manager',   2,  3,    50000),
 (12, N'Chloe Martin',    'chloe.martin@contoso.com',    N'Cloud Engineer',              2, 11,     5000),
 (13, N'Mateo Rossi',     'mateo.rossi@contoso.com',     N'Field Marketing Manager',     3,  4,    25000),
 (14, N'Aisha Khan',      'aisha.khan@contoso.com',      N'Account Executive',           4,  5,     5000),
 (15, N'Lucas Dubois',    'lucas.dubois@contoso.com',    N'Sales Operations Analyst',    4,  5,     5000),
 (16, N'Mia Johansson',   'mia.johansson@contoso.com',   N'Recruiting Lead',             5,  6,    10000),
 (17, N'Ethan Nakamura',  'ethan.nakamura@contoso.com',  N'Facilities Manager',          6,  7,    40000),
 (18, N'Zara Ahmed',      'zara.ahmed@contoso.com',      N'Logistics Coordinator',       6, 17,     5000),
 (19, N'Benjamin Clarke', 'benjamin.clarke@contoso.com', N'Contracts Specialist',        7,  8,    10000),
 (20, N'Isabella Silva',  'isabella.silva@contoso.com',  N'Research Scientist',          8,  9,    10000),
 (21, N'Ryan Patel',      'ryan.patel@contoso.com',      N'Software Engineer',           8,  9,     5000),
 (22, N'Ava Thompson',    'ava.thompson@contoso.com',    N'Accounts Payable Specialist', 1, 10,     2500);

INSERT dbo.Commodities (CommodityId, Name, UNSPSCSegment) VALUES
 (1, N'IT Hardware',              '43000000'),
 (2, N'Software & SaaS',          '43230000'),
 (3, N'Office Supplies',          '44000000'),
 (4, N'Professional Services',    '80000000'),
 (5, N'Facilities & Maintenance', '72000000'),
 (6, N'Marketing & Events',       '82000000'),
 (7, N'Logistics & Freight',      '78000000'),
 (8, N'Lab Equipment',            '41000000');

INSERT dbo.Suppliers (SupplierId, SupplierNumber, SupplierName, PrimaryCommodityId, Country, PaymentTerms, RiskRating, IsDiverseSupplier, Status, OnboardedDate) VALUES
 ( 1, 'SUP-10001', N'Contoso Computing Supply',        1, 'US', 'Net 30', 'Low',    0, 'Active',     '2019-03-12'),
 ( 2, 'SUP-10002', N'Litware Cloud Software',          2, 'US', 'Net 45', 'Low',    0, 'Active',     '2020-07-01'),
 ( 3, 'SUP-10003', N'Northwind Office Essentials',     3, 'US', 'Net 30', 'Low',    1, 'Active',     '2018-11-20'),
 ( 4, 'SUP-10004', N'Proseware Consulting Group',      4, 'GB', 'Net 60', 'Medium', 0, 'Active',     '2021-02-15'),
 ( 5, 'SUP-10005', N'Woodgrove Facility Services',     5, 'US', 'Net 30', 'Medium', 1, 'Active',     '2019-09-09'),
 ( 6, 'SUP-10006', N'Alpine Ski House Events',         6, 'CH', 'Net 30', 'Medium', 0, 'Active',     '2022-04-18'),
 ( 7, 'SUP-10007', N'Wide World Importers Freight',    7, 'SG', 'Net 45', 'High',   0, 'Active',     '2020-01-27'),
 ( 8, 'SUP-10008', N'Fabrikam Scientific Instruments', 8, 'DE', 'Net 60', 'Low',    0, 'Active',     '2017-06-05'),
 ( 9, 'SUP-10009', N'Adventure Works Hardware',        1, 'US', 'Net 30', 'Medium', 1, 'Active',     '2021-10-11'),
 (10, 'SUP-10010', N'Tailspin Digital Marketing',      6, 'US', 'Net 30', 'Low',    1, 'Active',     '2023-01-09'),
 (11, 'SUP-10011', N'Fourth Coffee Workplace',         5, 'US', 'Net 15', 'Low',    1, 'Active',     '2022-08-22'),
 (12, 'SUP-10012', N'Trey Research Advisory',          4, 'US', 'Net 45', 'Low',    0, 'Active',     '2020-05-30'),
 (13, 'SUP-10013', N'Blue Yonder Logistics',           7, 'NL', 'Net 30', 'Medium', 0, 'On Hold',    '2019-12-02'),
 (14, 'SUP-10014', N'Relecloud Security Software',     2, 'IE', 'Net 30', 'Low',    0, 'Active',     '2023-06-14'),
 (15, 'SUP-10015', N'Lamna Healthcare Lab Supply',     8, 'US', 'Net 30', 'High',   1, 'Onboarding', '2025-08-01');

INSERT dbo.CatalogItems (ItemId, SupplierId, CommodityId, ItemName, UnitOfMeasure, UnitPrice) VALUES
 ( 1,  1, 1, N'Laptop - 14in business ultrabook, 32GB RAM',            'EA',   1649.00),
 ( 2,  1, 1, N'27in 4K USB-C monitor',                                 'EA',    429.00),
 ( 3,  9, 1, N'Docking station, dual display',                         'EA',    219.00),
 ( 4,  9, 1, N'Wireless keyboard and mouse combo',                     'EA',     79.00),
 ( 5,  1, 1, N'Rack server, 2U dual-socket',                           'EA',  12800.00),
 ( 6,  2, 2, N'Collaboration suite subscription (annual, per user)',   'SEAT',  264.00),
 ( 7,  2, 2, N'Analytics platform license (annual)',                   'EA',  18500.00),
 ( 8, 14, 2, N'Endpoint protection subscription (annual, per device)', 'SEAT',   58.00),
 ( 9, 14, 2, N'Privileged access management (annual)',                 'EA',  24000.00),
 (10,  3, 3, N'Copy paper, letter, 10-ream case',                      'CS',     54.99),
 (11,  3, 3, N'Ergonomic office chair',                                'EA',    389.00),
 (12,  3, 3, N'Standing desk converter',                               'EA',    249.00),
 (13,  4, 4, N'Procurement transformation consulting (day rate)',      'DAY',  2200.00),
 (14, 12, 4, N'Market research study',                                 'EA',  35000.00),
 (15, 12, 4, N'Analyst advisory hours',                                'HR',    325.00),
 (16,  5, 5, N'HVAC preventive maintenance visit',                     'EA',   1150.00),
 (17,  5, 5, N'Janitorial services (monthly)',                         'MO',   6400.00),
 (18, 11, 5, N'Office pantry and coffee service (monthly)',            'MO',   1850.00),
 (19,  6, 6, N'Customer summit venue and catering package',            'EA',  42000.00),
 (20, 10, 6, N'Paid social campaign management (monthly)',             'MO',   7500.00),
 (21, 10, 6, N'Branded trade show booth',                              'EA',   9800.00),
 (22,  7, 7, N'Ocean freight container, 40ft',                         'EA',   4300.00),
 (23, 13, 7, N'Expedited air freight (per kg)',                        'KG',      9.40),
 (24,  8, 8, N'Benchtop centrifuge',                                   'EA',   7900.00),
 (25,  8, 8, N'Digital microscope with camera',                        'EA',   5400.00),
 (26, 15, 8, N'Nitrile gloves, box of 100',                            'BX',     14.50),
 (27, 15, 8, N'Sterile pipette tips, rack of 96',                      'RK',     11.25);

DECLARE @anchor datetime2(0) = DATEADD(hour, 17, CAST(CAST(GETDATE() AS date) AS datetime2(0)));
DECLARE @monthStart date = DATEFROMPARTS(YEAR(@anchor), MONTH(@anchor), 1);
DECLARE @employees int = (SELECT COUNT(*) FROM dbo.Employees);
DECLARE @items int = (SELECT COUNT(*) FROM dbo.CatalogItems);

INSERT dbo.Contracts (ContractNumber, SupplierId, Title, StartDate, EndDate, ContractValue, Currency, AutoRenew, OwnerId)
SELECT CONCAT('CTR-', 2000 + s.SupplierId), s.SupplierId,
       CONCAT(s.SupplierName, N' - Master Services Agreement'),
       DATEADD(month, -(s.SupplierId * 3), @monthStart),
       DATEADD(month, 36 - (s.SupplierId * 3), @monthStart),
       50000 * (1 + s.SupplierId % 7),
       CASE s.Country WHEN 'GB' THEN 'GBP' WHEN 'DE' THEN 'EUR' WHEN 'NL' THEN 'EUR' WHEN 'IE' THEN 'EUR' WHEN 'CH' THEN 'CHF' ELSE 'USD' END,
       CASE WHEN s.SupplierId % 3 = 0 THEN 1 ELSE 0 END,
       CASE WHEN s.SupplierId % 2 = 0 THEN 10 ELSE 19 END
FROM dbo.Suppliers s;

-- Requisitions: deterministic pseudo-random data spread over the last 12 months.
;WITH n AS (
    SELECT TOP (180) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
), r AS (
    SELECT i, ABS(CAST(CAST(HASHBYTES('MD5', CONCAT('req', i)) AS binary(4)) AS int)) AS h FROM n
)
INSERT dbo.Requisitions (ReqNumber, RequesterId, CostCenterId, Status, SubmittedAt, NeedByDate, Justification)
SELECT CONCAT('REQ-', 240000 + r.i),
       e.EmployeeId, e.CostCenterId,
       CASE WHEN r.h % 20 < 13 THEN 'Ordered'
            WHEN r.h % 20 < 15 THEN 'Approved'
            WHEN r.h % 20 < 18 THEN 'Pending Approval'
            WHEN r.h % 20 < 19 THEN 'Rejected'
            ELSE 'Draft' END,
       DATEADD(minute, -((365 - r.i * 2) * 1440 + r.h % 600), @anchor),
       CAST(DATEADD(day, 14 + r.h % 30 - (365 - r.i * 2), @anchor) AS date),
       CHOOSE(1 + r.h % 8, N'New hire onboarding equipment', N'Quarterly replenishment', N'Customer event support',
              N'Contract renewal', N'Project Phoenix rollout', N'Lab expansion', N'Replacement for end-of-life assets',
              N'Regional office refresh')
FROM r
JOIN dbo.Employees e ON e.EmployeeId = 1 + r.h % @employees;

;WITH k AS (SELECT v AS k FROM (VALUES (1), (2), (3), (4)) t(v)),
lines AS (
    SELECT rq.RequisitionId, k.k,
           ABS(CAST(CAST(HASHBYTES('MD5', CONCAT(rq.ReqNumber, '-', k.k)) AS binary(4)) AS int)) AS h,
           ABS(CAST(CAST(HASHBYTES('MD5', rq.ReqNumber) AS binary(4)) AS int)) AS hr
    FROM dbo.Requisitions rq CROSS JOIN k
)
INSERT dbo.RequisitionLines (RequisitionId, LineNumber, ItemId, Quantity, UnitPrice)
SELECT l.RequisitionId, l.k, ci.ItemId,
       CASE WHEN ci.UnitPrice >= 10000 THEN 1
            WHEN ci.UnitPrice >= 1000 THEN 1 + l.h % 5
            WHEN ci.UnitOfMeasure = 'KG' THEN 50 + l.h % 900
            ELSE 1 + l.h % 40 END,
       ci.UnitPrice
FROM lines l
JOIN dbo.CatalogItems ci ON ci.ItemId = 1 + l.h % @items
WHERE l.k <= 1 + l.hr % 4;

-- Approvals: manager approval, plus VP Procurement for requisitions over $25k.
;WITH totals AS (
    SELECT rq.RequisitionId, rq.RequesterId, rq.Status, rq.SubmittedAt, SUM(rl.LineTotal) AS Total
    FROM dbo.Requisitions rq JOIN dbo.RequisitionLines rl ON rl.RequisitionId = rq.RequisitionId
    WHERE rq.Status <> 'Draft'
    GROUP BY rq.RequisitionId, rq.RequesterId, rq.Status, rq.SubmittedAt
)
INSERT dbo.Approvals (RequisitionId, ApproverId, ApprovalStep, Decision, DecidedAt, Comments)
SELECT t.RequisitionId, COALESCE(e.ManagerId, 2), 1,
       CASE t.Status WHEN 'Pending Approval' THEN 'Pending' WHEN 'Rejected' THEN 'Rejected' ELSE 'Approved' END,
       CASE WHEN t.Status = 'Pending Approval' THEN NULL ELSE DATEADD(hour, 6, t.SubmittedAt) END,
       CASE t.Status WHEN 'Rejected' THEN N'Please source from a preferred contract supplier' END
FROM totals t JOIN dbo.Employees e ON e.EmployeeId = t.RequesterId
UNION ALL
SELECT t.RequisitionId, 2, 2,
       CASE WHEN t.Status = 'Pending Approval' THEN 'Pending' ELSE 'Approved' END,
       CASE WHEN t.Status = 'Pending Approval' THEN NULL ELSE DATEADD(hour, 20, t.SubmittedAt) END,
       NULL
FROM totals t
WHERE t.Total > 25000 AND t.Status <> 'Rejected';

-- Purchase orders: one PO per supplier on each ordered requisition.
;WITH po AS (
    SELECT rq.RequisitionId, ci.SupplierId, rq.SubmittedAt,
           ROW_NUMBER() OVER (ORDER BY rq.RequisitionId, ci.SupplierId) AS seq
    FROM dbo.Requisitions rq
    JOIN dbo.RequisitionLines rl ON rl.RequisitionId = rq.RequisitionId
    JOIN dbo.CatalogItems ci ON ci.ItemId = rl.ItemId
    WHERE rq.Status = 'Ordered'
    GROUP BY rq.RequisitionId, ci.SupplierId, rq.SubmittedAt
)
INSERT dbo.PurchaseOrders (PONumber, RequisitionId, SupplierId, Status, OrderDate, Currency, ShipToSite)
SELECT CONCAT('PO-', 780000 + po.seq), po.RequisitionId, po.SupplierId,
       CASE WHEN po.SubmittedAt < DATEADD(day, -90, @anchor) THEN 'Closed'
            WHEN po.SubmittedAt < DATEADD(day, -30, @anchor)
                 THEN CASE WHEN po.seq % 4 = 0 THEN 'Partially Received' ELSE 'Received' END
            ELSE 'Issued' END,
       CAST(DATEADD(day, 1 + po.seq % 3, po.SubmittedAt) AS date),
       'USD',
       CHOOSE(1 + po.seq % 4, N'Seattle HQ', N'Austin Campus', N'London Office', N'Singapore Hub')
FROM po;

INSERT dbo.PurchaseOrderLines (PurchaseOrderId, LineNumber, ItemId, Quantity, QuantityReceived, UnitPrice)
SELECT p.PurchaseOrderId,
       ROW_NUMBER() OVER (PARTITION BY p.PurchaseOrderId ORDER BY rl.LineNumber),
       rl.ItemId, rl.Quantity,
       CASE p.Status WHEN 'Issued' THEN 0
                     WHEN 'Partially Received' THEN CEILING(rl.Quantity / 2)
                     ELSE rl.Quantity END,
       rl.UnitPrice
FROM dbo.PurchaseOrders p
JOIN dbo.RequisitionLines rl ON rl.RequisitionId = p.RequisitionId
JOIN dbo.CatalogItems ci ON ci.ItemId = rl.ItemId AND ci.SupplierId = p.SupplierId;

COMMIT TRANSACTION;
GO

CREATE OR ALTER VIEW dbo.vw_SpendByCommodity AS
SELECT c.Name AS Commodity,
       COUNT(DISTINCT po.PurchaseOrderId) AS PurchaseOrders,
       SUM(pol.LineTotal) AS TotalSpend
FROM dbo.PurchaseOrders po
JOIN dbo.PurchaseOrderLines pol ON pol.PurchaseOrderId = po.PurchaseOrderId
JOIN dbo.CatalogItems ci ON ci.ItemId = pol.ItemId
JOIN dbo.Commodities c ON c.CommodityId = ci.CommodityId
GROUP BY c.Name;
GO

CREATE OR ALTER VIEW dbo.vw_SupplierSpend AS
SELECT s.SupplierNumber, s.SupplierName, s.RiskRating, s.IsDiverseSupplier,
       COUNT(DISTINCT po.PurchaseOrderId) AS PurchaseOrders,
       COALESCE(SUM(pol.LineTotal), 0) AS TotalSpend
FROM dbo.Suppliers s
LEFT JOIN dbo.PurchaseOrders po ON po.SupplierId = s.SupplierId
LEFT JOIN dbo.PurchaseOrderLines pol ON pol.PurchaseOrderId = po.PurchaseOrderId
GROUP BY s.SupplierNumber, s.SupplierName, s.RiskRating, s.IsDiverseSupplier;
GO

CREATE OR ALTER VIEW dbo.vw_BudgetVsSpend AS
SELECT cc.CostCenterCode, cc.Name AS CostCenter, cc.AnnualBudget,
       COALESCE(SUM(pol.LineTotal), 0) AS CommittedSpend,
       CAST(100.0 * COALESCE(SUM(pol.LineTotal), 0) / cc.AnnualBudget AS decimal(6,1)) AS PercentOfBudget
FROM dbo.CostCenters cc
LEFT JOIN dbo.Requisitions rq ON rq.CostCenterId = cc.CostCenterId
LEFT JOIN dbo.PurchaseOrders po ON po.RequisitionId = rq.RequisitionId
LEFT JOIN dbo.PurchaseOrderLines pol ON pol.PurchaseOrderId = po.PurchaseOrderId
GROUP BY cc.CostCenterCode, cc.Name, cc.AnnualBudget;
GO

/* =====================================================================
   CoupaInvoicing
   ===================================================================== */
USE CoupaInvoicing;
GO

IF OBJECT_ID(N'dbo.Invoices') IS NULL
CREATE TABLE dbo.Invoices (
    InvoiceId      int IDENTITY   NOT NULL PRIMARY KEY,
    InvoiceNumber  varchar(30)    NOT NULL,
    SupplierId     int            NOT NULL,   -- CoupaProcurement.dbo.Suppliers
    SupplierNumber varchar(12)    NOT NULL,
    PONumber       varchar(20)    NOT NULL,   -- CoupaProcurement.dbo.PurchaseOrders
    InvoiceDate    date           NOT NULL,
    DueDate        date           NOT NULL,
    Subtotal       decimal(14,2)  NOT NULL,
    TaxAmount      decimal(14,2)  NOT NULL,
    TotalAmount    AS (Subtotal + TaxAmount) PERSISTED,
    Currency       char(3)        NOT NULL,
    MatchStatus    varchar(20)    NOT NULL CHECK (MatchStatus IN ('3-Way Matched', 'Price Variance', 'Quantity Variance')),
    Status         varchar(20)    NOT NULL CHECK (Status IN ('Pending Approval', 'Approved', 'Paid', 'Disputed')),
    CONSTRAINT UQ_Invoices UNIQUE (SupplierId, InvoiceNumber)
);

IF OBJECT_ID(N'dbo.InvoiceLines') IS NULL
CREATE TABLE dbo.InvoiceLines (
    InvoiceLineId  int IDENTITY   NOT NULL PRIMARY KEY,
    InvoiceId      int            NOT NULL REFERENCES dbo.Invoices (InvoiceId),
    LineNumber     smallint       NOT NULL,
    Description    nvarchar(120)  NOT NULL,
    Quantity       decimal(10,2)  NOT NULL,
    UnitPrice      decimal(12,2)  NOT NULL,
    LineTotal      AS (CAST(Quantity * UnitPrice AS decimal(14,2))) PERSISTED
);

IF OBJECT_ID(N'dbo.Payments') IS NULL
CREATE TABLE dbo.Payments (
    PaymentId      int IDENTITY   NOT NULL PRIMARY KEY,
    InvoiceId      int            NOT NULL REFERENCES dbo.Invoices (InvoiceId),
    PaymentDate    date           NOT NULL,
    Amount         decimal(14,2)  NOT NULL,
    PaymentMethod  varchar(20)    NOT NULL CHECK (PaymentMethod IN ('ACH', 'Wire', 'Virtual Card', 'Check')),
    BankReference  varchar(30)    NOT NULL,
    EarlyPayDiscount decimal(12,2) NOT NULL
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Invoices_PONumber') CREATE INDEX IX_Invoices_PONumber ON dbo.Invoices (PONumber);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Invoices_Status') CREATE INDEX IX_Invoices_Status ON dbo.Invoices (Status);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_InvoiceLines_Invoice') CREATE INDEX IX_InvoiceLines_Invoice ON dbo.InvoiceLines (InvoiceId);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Payments_Invoice') CREATE INDEX IX_Payments_Invoice ON dbo.Payments (InvoiceId);
GO

IF EXISTS (SELECT 1 FROM dbo.Invoices) RETURN;

BEGIN TRANSACTION;

DECLARE @today date = CAST(GETDATE() AS date);

;WITH po AS (
    SELECT p.PurchaseOrderId, p.PONumber, p.SupplierId, s.SupplierNumber, s.PaymentTerms, p.OrderDate,
           SUM(CAST(pol.QuantityReceived * pol.UnitPrice AS decimal(14,2))) AS ReceivedValue,
           ABS(CAST(CAST(HASHBYTES('MD5', p.PONumber) AS binary(4)) AS int)) AS h
    FROM CoupaProcurement.dbo.PurchaseOrders p
    JOIN CoupaProcurement.dbo.PurchaseOrderLines pol ON pol.PurchaseOrderId = p.PurchaseOrderId
    JOIN CoupaProcurement.dbo.Suppliers s ON s.SupplierId = p.SupplierId
    WHERE p.Status IN ('Received', 'Partially Received', 'Closed')
    GROUP BY p.PurchaseOrderId, p.PONumber, p.SupplierId, s.SupplierNumber, s.PaymentTerms, p.OrderDate
    HAVING SUM(pol.QuantityReceived) > 0
), inv AS (
    SELECT po.*,
           DATEADD(day, 7 + h % 10, OrderDate) AS InvoiceDate,
           CAST(REPLACE(PaymentTerms, 'Net ', '') AS int) AS TermDays,
           CASE WHEN h % 25 = 0 THEN 'Price Variance' WHEN h % 31 = 0 THEN 'Quantity Variance' ELSE '3-Way Matched' END AS MatchStatus
    FROM po
)
INSERT dbo.Invoices (InvoiceNumber, SupplierId, SupplierNumber, PONumber, InvoiceDate, DueDate, Subtotal, TaxAmount, Currency, MatchStatus, Status)
SELECT CONCAT('INV-', SupplierNumber, '-', 5000 + PurchaseOrderId),
       SupplierId, SupplierNumber, PONumber, InvoiceDate,
       DATEADD(day, TermDays, InvoiceDate),
       CASE MatchStatus WHEN 'Price Variance' THEN CAST(ReceivedValue * 1.06 AS decimal(14,2)) ELSE ReceivedValue END,
       CAST(ReceivedValue * 0.0825 AS decimal(14,2)),
       'USD', MatchStatus,
       CASE WHEN MatchStatus <> '3-Way Matched' THEN 'Disputed'
            WHEN DATEADD(day, TermDays, InvoiceDate) < @today THEN 'Paid'
            WHEN h % 3 = 0 THEN 'Pending Approval'
            ELSE 'Approved' END
FROM inv;

INSERT dbo.InvoiceLines (InvoiceId, LineNumber, Description, Quantity, UnitPrice)
SELECT i.InvoiceId, pol.LineNumber, ci.ItemName, pol.QuantityReceived,
       CASE i.MatchStatus WHEN 'Price Variance' THEN CAST(pol.UnitPrice * 1.06 AS decimal(12,2)) ELSE pol.UnitPrice END
FROM dbo.Invoices i
JOIN CoupaProcurement.dbo.PurchaseOrders p ON p.PONumber = i.PONumber
JOIN CoupaProcurement.dbo.PurchaseOrderLines pol ON pol.PurchaseOrderId = p.PurchaseOrderId AND pol.QuantityReceived > 0
JOIN CoupaProcurement.dbo.CatalogItems ci ON ci.ItemId = pol.ItemId;

-- Every 5th paid invoice takes a 2% early-payment discount.
INSERT dbo.Payments (InvoiceId, PaymentDate, Amount, PaymentMethod, BankReference, EarlyPayDiscount)
SELECT i.InvoiceId,
       CASE WHEN i.InvoiceId % 5 = 0 THEN DATEADD(day, 10, i.InvoiceDate) ELSE DATEADD(day, -2, i.DueDate) END,
       CASE WHEN i.InvoiceId % 5 = 0 THEN CAST(i.TotalAmount * 0.98 AS decimal(14,2)) ELSE i.TotalAmount END,
       CHOOSE(1 + i.InvoiceId % 4, 'ACH', 'Virtual Card', 'Wire', 'ACH'),
       CONCAT('PMT', FORMAT(i.InvoiceId, '000000')),
       CASE WHEN i.InvoiceId % 5 = 0 THEN CAST(i.TotalAmount * 0.02 AS decimal(12,2)) ELSE 0 END
FROM dbo.Invoices i
WHERE i.Status = 'Paid';

COMMIT TRANSACTION;
GO

CREATE OR ALTER VIEW dbo.vw_InvoiceAging AS
SELECT i.InvoiceNumber, i.SupplierNumber, i.PONumber, i.InvoiceDate, i.DueDate, i.TotalAmount, i.Status,
       CASE WHEN i.Status = 'Paid' THEN 'Paid'
            WHEN DATEDIFF(day, i.DueDate, CAST(GETDATE() AS date)) <= 0 THEN 'Current'
            WHEN DATEDIFF(day, i.DueDate, CAST(GETDATE() AS date)) <= 30 THEN '1-30 days'
            WHEN DATEDIFF(day, i.DueDate, CAST(GETDATE() AS date)) <= 60 THEN '31-60 days'
            ELSE '60+ days' END AS AgingBucket
FROM dbo.Invoices i;
GO

/* =====================================================================
   CoupaExpenses
   ===================================================================== */
USE CoupaExpenses;
GO

IF OBJECT_ID(N'dbo.ExpenseCategories') IS NULL
CREATE TABLE dbo.ExpenseCategories (
    CategoryId          int            NOT NULL PRIMARY KEY,
    Name                nvarchar(40)   NOT NULL,
    PolicyLimit         decimal(10,2)  NOT NULL,   -- per expense item
    ReceiptRequiredOver decimal(10,2)  NOT NULL
);

IF OBJECT_ID(N'dbo.ExpenseReports') IS NULL
CREATE TABLE dbo.ExpenseReports (
    ExpenseReportId int IDENTITY  NOT NULL PRIMARY KEY,
    ReportNumber   varchar(20)    NOT NULL UNIQUE,
    EmployeeId     int            NOT NULL,   -- CoupaProcurement.dbo.Employees
    EmployeeEmail  varchar(120)   NOT NULL,
    Title          nvarchar(120)  NOT NULL,
    Status         varchar(20)    NOT NULL CHECK (Status IN ('Draft', 'Submitted', 'Approved', 'Reimbursed', 'Rejected')),
    SubmittedAt    datetime2(0)   NULL,
    ReimbursedAt   datetime2(0)   NULL
);

IF OBJECT_ID(N'dbo.ExpenseLines') IS NULL
CREATE TABLE dbo.ExpenseLines (
    ExpenseLineId   int IDENTITY  NOT NULL PRIMARY KEY,
    ExpenseReportId int           NOT NULL REFERENCES dbo.ExpenseReports (ExpenseReportId),
    CategoryId      int           NOT NULL REFERENCES dbo.ExpenseCategories (CategoryId),
    ExpenseDate     date          NOT NULL,
    Merchant        nvarchar(80)  NOT NULL,
    City            nvarchar(40)  NOT NULL,
    Amount          decimal(10,2) NOT NULL,
    Currency        char(3)       NOT NULL,
    ReceiptAttached bit           NOT NULL,
    OutOfPolicy     bit           NOT NULL
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ExpenseReports_Status') CREATE INDEX IX_ExpenseReports_Status ON dbo.ExpenseReports (Status);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ExpenseReports_Email') CREATE INDEX IX_ExpenseReports_Email ON dbo.ExpenseReports (EmployeeEmail);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ExpenseLines_Report') CREATE INDEX IX_ExpenseLines_Report ON dbo.ExpenseLines (ExpenseReportId);
GO

IF EXISTS (SELECT 1 FROM dbo.ExpenseCategories) RETURN;

BEGIN TRANSACTION;

DECLARE @base datetime2(0) = DATEADD(hour, 9, CAST(CAST(GETDATE() AS date) AS datetime2(0)));

INSERT dbo.ExpenseCategories (CategoryId, Name, PolicyLimit, ReceiptRequiredOver) VALUES
 (1, N'Airfare',              1500.00,  0),
 (2, N'Hotel',                 350.00,  0),
 (3, N'Meals',                  90.00, 25),
 (4, N'Ground Transport',      120.00, 25),
 (5, N'Conference Fees',      2500.00,  0),
 (6, N'Client Entertainment',  300.00, 25),
 (7, N'Home Office',           500.00, 75),
 (8, N'Mobile & Internet',     100.00, 75);

;WITH n AS (
    SELECT TOP (90) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i FROM sys.all_objects
), r AS (
    SELECT i, ABS(CAST(CAST(HASHBYTES('MD5', CONCAT('exp', i)) AS binary(4)) AS int)) AS h FROM n
)
INSERT dbo.ExpenseReports (ReportNumber, EmployeeId, EmployeeEmail, Title, Status, SubmittedAt, ReimbursedAt)
SELECT CONCAT('EXP-', 330000 + r.i), e.EmployeeId, e.Email,
       CHOOSE(1 + r.h % 8, N'Customer visit - Chicago', N'Sales kickoff - Las Vegas', N'Partner summit - London',
              N'Recruiting trip - Austin', N'Supplier audit - Singapore', N'Industry conference - Berlin',
              N'Home office setup', N'Quarterly business review - New York'),
       st.Status,
       CASE WHEN st.Status = 'Draft' THEN NULL ELSE DATEADD(day, -(365 - r.i * 4), @base) END,
       CASE WHEN st.Status = 'Reimbursed' THEN DATEADD(day, 9 - (365 - r.i * 4), @base) END
FROM r
JOIN CoupaProcurement.dbo.Employees e ON e.EmployeeId = 1 + r.h % 22
CROSS APPLY (SELECT CASE WHEN r.i > 85 THEN 'Draft'
                         WHEN r.i > 80 THEN 'Submitted'
                         WHEN r.i > 76 THEN 'Approved'
                         WHEN r.h % 17 = 0 THEN 'Rejected'
                         ELSE 'Reimbursed' END AS Status) st;

;WITH k AS (SELECT v AS k FROM (VALUES (1), (2), (3), (4), (5), (6)) t(v)),
lines AS (
    SELECT er.ExpenseReportId, er.Title, COALESCE(er.SubmittedAt, DATEADD(day, -2, @base)) AS BaseDate, k.k,
           ABS(CAST(CAST(HASHBYTES('MD5', CONCAT(er.ReportNumber, '-', k.k)) AS binary(4)) AS int)) AS h
    FROM dbo.ExpenseReports er CROSS JOIN k
    WHERE k.k <= 2 + ABS(CAST(CAST(HASHBYTES('MD5', er.ReportNumber) AS binary(4)) AS int)) % 5
), priced AS (
    SELECT l.*, CASE WHEN l.Title = N'Home office setup' THEN 7 + l.h % 2 ELSE 1 + l.h % 6 END AS CategoryId
    FROM lines l
)
INSERT dbo.ExpenseLines (ExpenseReportId, CategoryId, ExpenseDate, Merchant, City, Amount, Currency, ReceiptAttached, OutOfPolicy)
SELECT p.ExpenseReportId, p.CategoryId,
       CAST(DATEADD(day, -(1 + p.h % 5), p.BaseDate) AS date),
       CASE p.CategoryId
            WHEN 1 THEN CHOOSE(1 + p.h % 2, N'Blue Yonder Airlines', N'Contoso Air')
            WHEN 2 THEN CHOOSE(1 + p.h % 2, N'Margie''s Travel Hotels', N'Alpine Ski House Lodge')
            WHEN 3 THEN CHOOSE(1 + p.h % 3, N'Fourth Coffee', N'The Cheese Factory Bistro', N'Coho Winery Kitchen')
            WHEN 4 THEN CHOOSE(1 + p.h % 2, N'Contoso Rideshare', N'Tailspin Car Rental')
            WHEN 5 THEN N'Global Procurement Summit'
            WHEN 6 THEN N'Wingtip Steakhouse'
            WHEN 7 THEN N'Northwind Office Essentials'
            ELSE N'Southridge Wireless' END,
       CASE WHEN p.Title LIKE N'%Chicago' THEN N'Chicago' WHEN p.Title LIKE N'%Las Vegas' THEN N'Las Vegas'
            WHEN p.Title LIKE N'%London' THEN N'London' WHEN p.Title LIKE N'%Austin' THEN N'Austin'
            WHEN p.Title LIKE N'%Singapore' THEN N'Singapore' WHEN p.Title LIKE N'%Berlin' THEN N'Berlin'
            WHEN p.Title LIKE N'%New York' THEN N'New York' ELSE N'Remote' END,
       amt.Amount, 'USD',
       CASE WHEN amt.Amount > c.ReceiptRequiredOver OR p.h % 9 <> 0 THEN 1 ELSE 0 END,
       CASE WHEN amt.Amount > c.PolicyLimit THEN 1 ELSE 0 END
FROM priced p
JOIN dbo.ExpenseCategories c ON c.CategoryId = p.CategoryId
CROSS APPLY (SELECT CAST(c.PolicyLimit * (0.35 + (p.h % 80) / 100.0) AS decimal(10,2)) AS Amount) amt;

COMMIT TRANSACTION;
GO

CREATE OR ALTER VIEW dbo.vw_ExpenseSummary AS
SELECT er.ReportNumber, er.EmployeeEmail, er.Title, er.Status,
       COUNT(el.ExpenseLineId) AS Lines,
       SUM(el.Amount) AS TotalAmount,
       SUM(CASE WHEN el.OutOfPolicy = 1 THEN 1 ELSE 0 END) AS OutOfPolicyLines
FROM dbo.ExpenseReports er
LEFT JOIN dbo.ExpenseLines el ON el.ExpenseReportId = er.ExpenseReportId
GROUP BY er.ReportNumber, er.EmployeeEmail, er.Title, er.Status;
GO

USE master;
GO
