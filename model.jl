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

colors = zip_cols(tech_df, :Technologies, :Color)

merge!(colors, zip_cols(storages_df, :Storages, :Color))

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

  Investments = DataFrame((
      Technology=tech,
      Renewable=!(tech in NONRES),
      Storage= tech in STOR,
      Capacity=value(CAP_G[tech]),
      Generation=sum(value(G[tech, h]*scale/1000) for h in HOURS),
      InvestmentCost=sum(invcost[tech] * value(CAP_G[tech])/1000),
      GenerationCost=sum(mc[tech] * value(G[tech,hour])*scale/1000 for hour in HOURS),
      Color=Symbol(colors[tech]))
      for tech in TECH)

  Investments[:FLH] = Investments[:Generation] ./ Investments[:Capacity]

  filter!(x-> x[:Capacity] > 0, Investments)

  Investments


  ### Plot Investments
  inv_plot = @df Investments bar(:Technology, :Capacity, color=:Color,
      title="Investment", ylabel="GW", leg=false, rotation=-45)

  ### Plot Total Gen ###
  gen_plot = @df Investments bar(:Technology, :Generation, color=:Color,
      title="Total Generation", ylabel="TWh", leg=false, rotation=-45)

  ### Plots RES share ###
  total_res_gen = sum(Investments[Investments[:Renewable] .== true, :Generation])
  total_gen = sum(Investments[:Generation])
  res_share = total_res_gen*100 / total_gen

  storage_util = sum(Investments[Investments[:Storage] .== true, :Generation])*100/total_gen

  res_share_plot = bar(["Renewable share" "Storage Output"],
      [res_share storage_util],
      lab=["" ""],
      ylab="%",
      ylim=(0,100))

  l = @layout [grid(2,1) a{0.3w}]
  plot(gen_plot, inv_plot, res_share_plot, layout=l, titlefont=8, xtickfont=6)
