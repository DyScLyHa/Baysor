using ProgressMeter
using Statistics
using StatsBase
using Random

import Distributions.pdf

CatMixture = Matrix{Float64}
Nullable{T} = Union{T, Nothing}

struct FNormal
    μ::Float64
    σ::Float64
    c::Float64
    s::Float64
end

FNormal(μ::Float64, σ::Float64) = FNormal(μ, σ, -0.5 * log(2 * π) - log(σ), 0.5 / σ^2)

struct NormalComponent
    dists::Vector{FNormal}
    n::Float64
end

NormMixture = Vector{NormalComponent}

@inline normal_logpdf(n::FNormal, v::Float64) = n.c - (v - n.μ)^2 * n.s
# @inline normal_logpdf(n::FNormal, v::Float64) = n.σ - (v - n.μ)^2 / n.σ
@inline normal_logpdf(a::Float64, b::Float64) = a * b

function pdf(comp::NormalComponent, vec::AbstractVector{Float64})
    dens = 0.0
    for i in eachindex(vec)
        dens += normal_logpdf(comp.dists[i], vec[i])
    end

    return comp.n * exp(dens)
end

function test_pdf_perf2(gene_vecs::Matrix{Float64})
    g = gene_vecs[1]
    for _ in 1:1000000
        normal_logpdf(g, 1.0)
    end
end

function test_pdf_perf(comp::NormalComponent, gene_vecs::Matrix{Float64})
    d = 0
    for i in 1:10
        for _ in 1:size(gene_vecs, 2)
            d += pdf(comp, view(gene_vecs, :, i))
        end
    end
    return d
end

@inline comp_pdf(cell_type_exprs::CatMixture, ci::Int, factor::Int) = cell_type_exprs[ci, factor]
@inline comp_pdf(comps::NormMixture, ci::Int, vec::AbstractVector{Float64}) = pdf(comps[ci], vec)

function maximize_molecule_clusters!(
        cell_type_exprs::CatMixture, genes::Vector{Int}, confidence::Vector{Float64}, assignment_probs::Matrix{Float64};
        prior_exprs::Nullable{Matrix{Float64}}=nothing, prior_stds::Nullable{Matrix{Float64}}=nothing,
        add_pseudocount::Bool=false
    )
    cell_type_exprs .= 0.0;
    for i in 1:length(genes)
        t_gene = genes[i];
        t_conf = confidence[i];

        for j in 1:size(cell_type_exprs, 1)
            cell_type_exprs[j, t_gene] += t_conf * assignment_probs[j, i];
        end
    end

    if prior_exprs !== nothing
        mult = sum(cell_type_exprs, dims=2)
        cell_type_exprs .= adj_value_norm.(cell_type_exprs, prior_exprs .* mult, prior_stds .* mult)
    end

    if add_pseudocount
        cell_type_exprs .= (cell_type_exprs .+ 1) ./ (sum(cell_type_exprs, dims=2) .+ 1);
    else
        cell_type_exprs ./= sum(cell_type_exprs, dims=2);
    end
end

function maximize_molecule_clusters!(
        components::NormMixture, gene_vecs::Matrix{Float64}, confidence::Vector{Float64}, assignment_probs::Matrix{Float64}
    )
    @threads for ci in eachindex(components)
        c_weights = assignment_probs[ci, :] .* confidence
        components[ci] = NormalComponent(
            [FNormal(wmean_std(view(gene_vecs, i, :), c_weights)...) for i in 1:size(gene_vecs, 1)],
            sum(c_weights)
        )
    end
end

@inline get_gene_vec(genes::Vector{Int}, i::Int) = genes[i]
@inline get_gene_vec(genes::Matrix{Float64}, i::Int) = view(genes, :, i)

"""
Params:
- adjacent_weights: must be multiplied by confidence of the corresponding adjacent_point
"""
function expect_molecule_clusters!(
        assignment_probs::Matrix{Float64}, assignment_probs_prev::Matrix{Float64},
        cell_type_exprs::Union{CatMixture, NormMixture},
        genes::Union{Vector{Int}, Matrix{Float64}},
        adjacent_points::Vector{Vector{Int}}, adjacent_weights::Vector{Vector{Float64}};
        mrf_weight::Float64=1.0, only_mrf::Bool=false, is_fixed::Nullable{BitVector}=nothing
    )
    total_ll = Atomic{Float64}(0.0)
    @threads for i in eachindex(adjacent_points)
        (is_fixed === nothing || !is_fixed[i]) || continue
        gene = get_gene_vec(genes, i)
        cur_weights = adjacent_weights[i]
        cur_points = adjacent_points[i]

        dense_sum = 0.0
        for ri in 1:size(assignment_probs, 1)
            c_d = 0.0
            for j in eachindex(cur_points)
                a_p = assignment_probs_prev[ri, cur_points[j]]
                (a_p > 1e-5) || continue

                c_d += cur_weights[j] * a_p
            end

            mrf_prior = exp(c_d * mrf_weight)
            if only_mrf
                assignment_probs[ri, i] = mrf_prior
            else
                assignment_probs[ri, i] = comp_pdf(cell_type_exprs, ri, gene) * mrf_prior
            end
            dense_sum += assignment_probs[ri, i]
        end

        # total_ll += log10(dense_sum)
        atomic_add!(total_ll, log10(dense_sum)) # TODO: it slows down the code a lot
        if dense_sum .> 1e-20
            @views assignment_probs[:, i] ./= dense_sum
        else
            @views assignment_probs[:, i] .= 1 / size(assignment_probs, 1)
        end
    end

    return total_ll[]
end


function cluster_molecules_on_mrf(df_spatial::DataFrame, adjacent_points::Vector{Vector{Int}}, adjacent_weights::Vector{Vector{Float64}};
        n_clusters::Int, confidence_threshold::Float64=0.95, kwargs...)

    cor_mat = pairwise_gene_spatial_cor(df_spatial.gene, df_spatial.confidence, adjacent_points, adjacent_weights; confidence_threshold=confidence_threshold);
    ct_exprs_init = nothing
    try
        ica_fit = fit(MultivariateStats.ICA, cor_mat, n_clusters, maxiter=10000);
        ct_exprs_init = copy((abs.(ica_fit.W) ./ sum(abs.(ica_fit.W), dims=1))')
    catch
        @warn "ICA did not converge, fall back to random initialization"
    end

    return cluster_molecules_on_mrf(df_spatial.gene, adjacent_points, adjacent_weights, df_spatial.confidence;
        cell_type_exprs=ct_exprs_init, n_clusters=n_clusters, kwargs...)
end


function init_cell_type_exprs(
        genes::Vector{Int},
        cell_type_exprs::Nullable{<:AbstractMatrix{Float64}}=nothing, assignment::Nullable{Vector{Int}}=nothing;
        n_clusters::Int=1, init_mod::Int=10000
    )::CatMixture
    (cell_type_exprs === nothing) || return deepcopy(Matrix(cell_type_exprs))

    if n_clusters <= 1
        (assignment !== nothing) || error("Either n_clusters, assignment or cell_type_exprs must be specified")

        n_clusters = maximum(assignment)
    end

    if init_mod < 0
        cell_type_exprs = copy(hcat(prob_array.(
            split(genes, rand(1:n_clusters, length(genes))), max_value=maximum(genes)
        )...)')
    else
        gene_probs = prob_array(genes)
        cell_type_exprs = gene_probs' .* (0.95 .+ (hcat([[hash(x1 * x2^2) for x2 in 1:n_clusters] for x1 in 1:length(gene_probs)]...) .% init_mod) ./ 100000) # determenistic way of adding pseudo-random noise
    end
    # cell_type_exprs ./= sum(cell_type_exprs, dims=2)
    cell_type_exprs = (cell_type_exprs .+ 1) ./ (sum(cell_type_exprs, dims=2) .+ 1)

    return cell_type_exprs
end

init_assignment_probs_inner(genes::Vector{Int}, cell_type_exprs::CatMixture) = cell_type_exprs[:, genes]

function init_assignment_probs(assignment::Vector{Int})
    assignment_probs = zeros(maximum(assignment), length(assignment));
    assignment_probs[CartesianIndex.(assignment, 1:length(assignment))] .= 1.0;
    return assignment_probs
end

function init_assignment_probs(
        genes::Vector{Int}, cell_type_exprs::Nullable{CatMixture};
        assignment::Nullable{Vector{Int}}=nothing, assignment_probs::Nullable{Matrix{Float64}}=nothing
    )
    (assignment_probs === nothing) || return deepcopy(assignment_probs)
    (assignment === nothing) || return init_assignment_probs(assignment)

    assignment_probs = init_assignment_probs_inner(genes, cell_type_exprs)
    assignment_probs[:, vec(sum(assignment_probs, dims=1)) .< 1e-10] .= 1 / size(assignment_probs, 1)
    assignment_probs ./= sum(assignment_probs, dims=1)

    return assignment_probs
end

function init_categorical_mixture(
        genes::Vector{Int}, cell_type_exprs::Nullable{CatMixture}=nothing,
        assignment::Nullable{Vector{Int}}=nothing, assignment_probs::Nullable{Matrix{Float64}}=nothing;
        n_clusters::Int=1, init_mod::Int=10000
    )

    cell_type_exprs = init_cell_type_exprs(genes, cell_type_exprs, assignment; n_clusters, init_mod)
    assignment_probs = init_assignment_probs(genes, cell_type_exprs; assignment, assignment_probs)

    return cell_type_exprs, assignment_probs
end

function init_normal_cluster_mixture(
        gene_vectors::Matrix{Float64}, assignment::Vector{Int}
    )

    # TODO: move clustering here, add all optional parameters
    n_clusters = maximum(assignment)
    components = [NormalComponent([FNormal(0.0, 1.0) for _ in 1:size(gene_vectors, 1)], 1) for _ in 1:n_clusters];
    assignment_probs = init_assignment_probs(assignment);

    return components, assignment_probs
end

function cluster_molecules_on_mrf(
        genes::Union{Vector{Int}, Matrix{Float64}}, adjacent_points::Vector{Vector{Int}}, adjacent_weights::Vector{Vector{Float64}}, confidence::Vector{Float64};
        n_clusters::Int=1, tol::Float64=0.01, do_maximize::Bool=true, max_iters::Int=max(10000, div(length(genes), 200)), n_iters_without_update::Int=20,
        components::Union{CatMixture, NormMixture, Nothing}=nothing,
        assignment::Nullable{Vector{Int}}=nothing, assignment_probs::Nullable{Matrix{Float64}}=nothing,
        verbose::Bool=true, progress::Nullable{Progress}=nothing, weights_pre_adjusted::Bool=false, weight_mult::Float64=1.0, init_mod::Int=10000,
        method::Symbol=:normal, kwargs...
    )
    # Initialization

    if !weights_pre_adjusted
        adjacent_weights = [weight_mult .* adjacent_weights[i] .* confidence[adjacent_points[i]] for i in 1:length(adjacent_weights)] # instead of multiplying each time in expect
    end

    if method == :normal
        components, assignment_probs = init_normal_cluster_mixture(genes, assignment)
    elseif method == :categorical
        components, assignment_probs = init_categorical_mixture(genes, components, assignment, assignment_probs; n_clusters, init_mod)
    else
        error("Unknown method: $method")
    end

    assignment_probs_prev = deepcopy(assignment_probs)
    max_diffs = Float64[]
    change_fracs = Float64[]

    if verbose && (progress === nothing)
        progress = Progress(max_iters, 0.3)
    end

    # EM iterations
    n_iters = 0
    for i in 1:max_iters
        n_iters = i
        assignment_probs_prev .= assignment_probs

        expect_molecule_clusters!(
            assignment_probs, assignment_probs_prev, components, genes,
            adjacent_points, adjacent_weights
        )

        if do_maximize
            maximize_molecule_clusters!(components, genes, confidence, assignment_probs; add_pseudocount=true, kwargs...)
        end

        md, cf = estimate_difference_l0(assignment_probs, assignment_probs_prev, col_weights=confidence)
        push!(max_diffs, md)
        push!(change_fracs, cf)

        prog_vals = [("Iteration", i), ("Max. difference", md), ("Fraction of probs changed", cf)]
        if verbose
            next!(progress, showvalues=prog_vals)
        end

        if (i > n_iters_without_update) && (maximum(max_diffs[(end - n_iters_without_update):end]) < tol)
            if verbose
                finish!(progress, showvalues=prog_vals)
            end
            break
        end
    end

    if verbose
        @info "Algorithm stopped after $n_iters iterations. Error: $(round(max_diffs[end], sigdigits=3)). Converged: $(max_diffs[end] <= tol)."
    end

    if do_maximize
        maximize_molecule_clusters!(components, genes, confidence, assignment_probs, add_pseudocount=false)
    end

    assignment = vec(mapslices(x -> findmax(x)[2], assignment_probs, dims=1));

    return (exprs=components, assignment=assignment, diffs=max_diffs, assignment_probs=assignment_probs, change_fracs=change_fracs)
end

function filter_small_molecule_clusters(genes::Vector{Int}, confidence::Vector{Float64}, adjacent_points::Vector{Vector{Int}},
        assignment_probs::Matrix{Float64}, cell_type_exprs::Matrix{Float64}; min_mols_per_cell::Int, confidence_threshold::Float64=0.95)

    assignment = vec(mapslices(x -> findmax(x)[2], assignment_probs, dims=1));
    conn_comps_per_clust = get_connected_components_per_label(assignment, adjacent_points, 1;
        confidence=confidence, confidence_threshold=confidence_threshold)[1];
    n_mols_per_comp_per_clust = [length.(c) for c in conn_comps_per_clust];

    real_clust_ids = findall(maximum.(n_mols_per_comp_per_clust) .>= min_mols_per_cell)

    if length(real_clust_ids) == size(assignment_probs, 1)
        return assignment_probs, n_mols_per_comp_per_clust, real_clust_ids
    end

    assignment_probs = assignment_probs[real_clust_ids,:];
    cell_type_exprs = cell_type_exprs[real_clust_ids,:];

    for i in findall(vec(sum(assignment_probs, dims=1) .< 1e-10))
        assignment_probs[:, i] .= cell_type_exprs[:, genes[i]]
    end

    assignment_probs ./= sum(assignment_probs, dims=1);

    return assignment_probs, n_mols_per_comp_per_clust[real_clust_ids], real_clust_ids
end

## Utils

"""
    Adjust value based on prior. Doesn't penalize values < σ, penalize linearly values in [σ; 3σ], and super-linarly all >= 3σ
"""
@inline function adj_value_norm(x::Float64, μ::Float64, σ::Float64)::Float64
    dx = x - μ
    z = abs(dx) / σ
    if z < 1
        return x
    end

    if z < 3
        return μ + sign(dx) * (1 + (z - 1) / 4) * σ
    end

    return μ + sign(dx) * (sqrt(z) + 1.5 - sqrt(3)) * σ
end

function pairwise_gene_spatial_cor(
        genes::Vector{Int}, confidence::Vector{Float64}, adjacent_points::Array{Vector{Int}, 1}, adjacent_weights::Array{Vector{Float64}, 1};
        confidence_threshold::Float64=0.95
    )::Matrix{Float64}
    gene_cors = zeros(maximum(genes), maximum(genes))
    sum_weight_per_gene = zeros(maximum(genes))
    for gi in 1:length(genes)
        cur_adj_points = adjacent_points[gi]
        cur_adj_weights = adjacent_weights[gi]
        g2 = genes[gi]
        if confidence[gi] < confidence_threshold
            continue
        end

        for ai in eachindex(cur_adj_points)
            if confidence[cur_adj_points[ai]] < confidence_threshold
                continue
            end

            g1 = genes[cur_adj_points[ai]]
            cw = cur_adj_weights[ai]
            gene_cors[g2, g1] += cw
            sum_weight_per_gene[g1] += cw
            sum_weight_per_gene[g2] += cw
        end
    end

    for ci in eachindex(sum_weight_per_gene)
        for ri in eachindex(sum_weight_per_gene)
            gene_cors[ri, ci] /= fmax(sqrt(sum_weight_per_gene[ri] * sum_weight_per_gene[ci]), 0.1)
        end
    end

    return gene_cors
end

## Wrappers

function estimate_molecule_clusters(df_spatial::DataFrame, n_clusters::Int)
    @info "Clustering molecules..."
    # , adjacency_type=:both, k_adj=fmax(1, div(args["min-molecules-per-cell"], 2))
    adjacent_points, adjacent_weights = build_molecule_graph_normalized(df_spatial, :confidence, filter=false);

    mol_clusts = cluster_molecules_on_mrf(df_spatial, adjacent_points, adjacent_weights; n_clusters=n_clusters, weights_pre_adjusted=false)

    @info "Done"
    return mol_clusts
end