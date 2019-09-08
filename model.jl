using JuMP
#using Clp
using Gurobi
using DataFrames, CSV
using Plots; pyplot()
using StatsPlots

# initialize constants
co2_price = 180
i = 0.04

# Read the Excel sheets for tech, storage and timeseries
tech_df = CSV.read(joinpath("data","technologies.csv"))
storages_df = CSV.read(joinpath("data","storages.csv"))
timeseries_df = CSV.read(joinpath("data","timeseries.csv"))
# Creating strings for the different technologies
STOR = storages_df[:Storages] |> Array
TECH = vcat(tech_df[:Technologies], STOR)
NONSTOR = setdiff(TECH, STOR)
RES = [row[:Technologies] for row in eachrow(tech_df) if row[:Renewable] == 1]
NONRES = [row[:Technologies] for row in eachrow(tech_df) if row[:Renewable] == 0]
DISP = [row[:Technologies] for row in eachrow(tech_df) if row[:Dispatchable] == 1]
NONDISP = [t for t in TECH if Symbol(t) in names(timeseries_df)]

# collect Dataframes
zip_cols(df::DataFrame, col1::Symbol, col2::Symbol) = Dict(collect(zip(df[col1],df[col2])))

tech_df[:mc] = tech_df[:FuelCost] ./ tech_df[:Efficiency] .+ tech_df[:CarbonContent]*co2_price
mc = zip_cols(tech_df, :Technologies, :mc)
mc_stor = zip_cols(storages_df, :Storages, :MarginalCost)
merge!(mc, mc_stor)
HOURS = collect(1:8760)

annuity(i,lifetime) = i*((1+i)^lifetime) / (((1+i)^lifetime)-1)

tech_df.AnnualizedInvestmentCost =
    tech_df[:OvernightCost] .* [annuity.(i,lt) for lt in tech_df[:Lifetime]]
storages_df[:AnnualizedCapacityCost] =
        storages_df[:OvernightCostEnergy] .* [annuity.(i,lt) for lt in storages_df[:Lifetime]]
storages_df[:AnnualizedPowerCost] =
        storages_df[:OvernightCostPower] .* [annuity.(i,lt) for lt in storages_df[:Lifetime]]

invcost = zip_cols(tech_df, :Technologies, :AnnualizedInvestmentCost)
invcapacitycost = zip_cols(storages_df, :Storages, :AnnualizedCapacityCost)
invpowercost = zip_cols(storages_df, :Storages, :AnnualizedPowerCost)

merge!(invcost, invpowercost)

avail = Dict(nondisp => Array(timeseries_df[Symbol(nondisp)]) for nondisp in NONDISP)
demand = timeseries_df[:load] |> Array

max_gen = zip_cols(tech_df, :Technologies, :MaxEnergy)


max_instal = zip_cols(tech_df, :Technologies, :MaxInstallable)

HOURS = collect(1:8760)

scale = 8760/length(HOURS)

dispatch = Model(with_optimizer(Gurobi.Optimizer))
@variables dispatch begin
        G[TECH, HOURS] >= 0
        D_Stor[STOR, HOURS] >= 0
        L_Stor[STOR, HOURS] >= 0
        CAP_G[TECH] >= 0
        CAP_STOR[STOR] >= 0
end

@objective(dispatch, Min,
        sum(mc[tech] * G[tech, hour] for tech in TECH, hour in HOURS)
        + sum(invcost[tech] * CAP_G[tech] for tech in TECH)
        + sum(invcapacitycost[stor] * CAP_STOR[stor] for stor in STOR)
)
@constraint(dispatch,  Max_Generation[tech=TECH, hour=HOURS],
        G[tech, hour]
        <=
        (haskey(avail, tech) ? avail[tech][hour] * CAP_G[tech] : CAP_G[tech])
);
@constraint(dispatch, Storage_Discharge[stor=STOR, hour=HOURS],
    D_Stor[stor, hour] <= CAP_G[stor]);

@constraint(dispatch, Storage_Capacity[stor=STOR, hour=HOURS],
  L_Stor[stor, hour] <= CAP_STOR[stor]);

@constraint(dispatch, MaxInstallable[tech=NONSTOR; max_instal[tech] >= 0],
        CAP_G[tech] <= max_instal[tech] );
@constraint(dispatch, MaxTotalGeneration[tech=NONSTOR; max_gen[tech] >= 0],
  sum(G[tech, hour] * scale for hour in HOURS) <= max_gen[tech] );

@constraint(dispatch, EnergyBalance[hour=HOURS],
  sum(G[tech, hour] for tech in TECH) == demand[hour]
                                       + sum(D_Stor[stor, hour] for stor in STOR));

@constraint(dispatch, Storage_Balace[stor=STOR, hour=HOURS],
  L_Stor[stor, hour]

  ==

  (hour > HOURS[1] ? L_Stor[stor, hour - 1] : L_Stor[stor, HOURS[end]])
  - G[stor, hour]
  + D_Stor[stor, hour]);

  JuMP.optimize!(dispatch)
  JuMP.objective_value(dispatch)
