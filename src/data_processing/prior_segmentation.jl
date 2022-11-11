using NearestNeighbors
using SparseArrays
using StatsBase

@lazy import ImageCore = "a09fc81d-aa75-5fe9-8630-4744c3626534"
@lazy import ImageMagick = "6218d12a-5da1-5696-b52f-db25d2ecc6d1"
@lazy import MAT = "23992714-dd62-5051-b70f-ba57cb901cac"

function load_segmentation_mask(path::String)::SparseMatrixCSC
    if lowercase(splitext(path)[end]) == ".mat"
        labels = first(MAT.matread(path))[2]
        if !(typeof(labels) <: Integer)
            for v in labels
                if (v < -1e-5) || (abs(round(Int, v) - v) > 1e-5)
                    error(".mat file must have non-negative integer array with labels in its first slot, but it contains value '$v'")
                end
            end
        end

        return SparseMatrixCSC{Int, Int}(labels)
    end

    labels = ImageMagick.load(path) |> ImageCore.channelview |> ImageCore.rawview |> sparse |> dropzeros!
    if length(unique(nonzeros(labels))) == 1
        return BitMatrix(labels) |> ImageMorphology.label_components |> sparse
    end

    return labels
end

estimate_scale_from_centers(radius_per_segment::Vector{Float64}) =
    (median(radius_per_segment), mad(radius_per_segment; normalize=true))

"""
Estimates scale as a 0.5 * median distance between two nearest centers
"""
estimate_scale_from_centers(centers::Matrix{Float64}) =
    estimate_scale_from_centers(maximum.(knn(KDTree(centers), centers, 2)[2]) ./ 2)

estimate_scale_from_centers(seg_labels::Matrix{<:Integer}) =
    estimate_scale_from_centers(sqrt.(ImageMorphology.component_lengths(seg_labels)[2:end] ./ π))

function estimate_scale_from_centers(seg_labels::SparseMatrixCSC{<:Integer})
    nz_vals = nonzeros(seg_labels);
    nz_vals = nz_vals[nz_vals .> 0]
    if isempty(nz_vals)
        error("No transcripts detected inside the segmented regions. Please, check that transcript coordinates match those in the segmentation mask.")
    end
    return estimate_scale_from_centers(sqrt.(filter(x -> x > 0, count_array(nz_vals)) ./ π))
end

function estimate_scale_from_assignment(pos_data::Matrix{Float64}, assignment::Vector{Int}; min_mols_per_cell::Int)
    pd_per_cell = [pos_data[:,ids] for ids in split_ids(assignment, drop_zero=true) if length(ids) >= min_mols_per_cell];
    if length(pd_per_cell) < 3
        error("Not enough prior cells pass the min_mols_per_cell=$(min_mols_per_cell) threshold. Please, specify scale manually.")
    end
    return estimate_scale_from_centers(hcat(mean.(pd_per_cell, dims=2)...))
end

filter_segmentation_labels!(segment_per_transcript::Vector{<:Integer}; kwargs...) =
    filter_segmentation_labels!(segment_per_transcript, segment_per_transcript; kwargs...)[1]

filter_segmentation_labels!(segmentation_labels::MT where MT <: AbstractMatrix{<:Integer}, df_spatial::DataFrame; quiet::Bool=false, kwargs...) =
    filter_segmentation_labels!(segmentation_labels, staining_value_per_transcript(df_spatial, segmentation_labels, quiet=quiet); kwargs...)

function filter_segmentation_labels!(segmentation_labels::SparseMatrixCSC{<:Integer}, segment_per_transcript::Vector{<:Integer}; kwargs...)
    filter_segmentation_labels!(segmentation_labels.nzval, segment_per_transcript; kwargs...)
    dropzeros!(segmentation_labels)
    return segmentation_labels
end

function filter_segmentation_labels!(segmentation_labels::MT where MT <: AbstractArray{<:Integer}, segment_per_transcript::Vector{<:Integer}; min_molecules_per_segment::Int)
    n_mols_per_label = count_array(segment_per_transcript, max_value=maximum(segmentation_labels), drop_zero=true)

    for labs in (segmentation_labels, segment_per_transcript)
        for i in 1:length(labs)
            lab = labs[i]
            if (lab > 0) && (n_mols_per_label[lab] < min_molecules_per_segment)
                labs[i] = 0
            end
        end
    end

    return (segmentation_labels, segment_per_transcript)
end
