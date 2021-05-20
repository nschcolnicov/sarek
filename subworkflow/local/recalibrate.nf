/*
================================================================================
                                   RECALIBRATE
================================================================================
*/

params.applybqsr_options      = [:]
params.merge_bam_options      = [:]
params.qualimap_bamqc_options = [:]
params.samtools_index_options = [:]
params.samtools_stats_options = [:]

include { GATK4_APPLYBQSR as APPLYBQSR } from '../../modules/nf-core/software/gatk4/applybqsr/main' addParams(options: params.applybqsr_options)
include { QUALIMAP_BAMQC }               from '../../modules/nf-core/software/qualimap/bamqc/main'  addParams(options: params.qualimap_bamqc_options)
include { SAMTOOLS_INDEX }               from '../../modules/nf-core/software/samtools/index/main'  addParams(options: params.samtools_index_options)
include { SAMTOOLS_MERGE }               from '../../modules/nf-core/software/samtools/merge/main'  addParams(options: params.merge_bam_options)
include { SAMTOOLS_STATS }               from '../../modules/nf-core/software/samtools/stats/main'  addParams(options: params.samtools_stats_options)

workflow RECALIBRATE {
    take:
        skip_bamqc     // boolean: true/false
        skip_samtools  // boolean: true/false
        bam            // channel: [mandatory] bam
        dict           // channel: [mandatory] dict
        fai            // channel: [mandatory] fai
        fasta          // channel: [mandatory] fasta
        intervals      // channel: [mandatory] intervals
        step           //   value: [mandatory] starting step
        target_bed     // channel: [optional]  target_bed

    main:

    bam_recalibrated_index = Channel.empty()
    bam_recalibrated       = Channel.empty()
    bam_reports            = Channel.empty()

    if (step in ["mapping", "preparerecalibration", "recalibrate"]) {

        bam_intervals = bam.combine(intervals)

        APPLYBQSR(bam_intervals, fasta, fai, dict)

        // STEP 4.5: MERGING AND INDEXING THE RECALIBRATED BAM FILES
        if (params.no_intervals) {
            bam_recalibrated = APPLYBQSR.out.bam
        } else {
            APPLYBQSR.out.bam.map{ meta, bam -> //, bai ->
                patient = meta.patient
                sample  = meta.sample
                gender  = meta.gender
                status  = meta.status
                [patient, sample, gender, status, bam] //, bai]
            }.groupTuple(by: [0,1]).set{ bam_recalibrated_interval }

            bam_recalibrated_interval = bam_recalibrated_interval.map {
                patient, sample, gender, status, bam -> //, bai ->

                def meta = [:]
                meta.patient = patient
                meta.sample = sample
                meta.gender = gender[0]
                meta.status = status[0]
                meta.id = sample

                [meta, bam]
            }

            SAMTOOLS_MERGE(bam_recalibrated_interval)
            bam_recalibrated = SAMTOOLS_MERGE.out.merged_bam
        }

        SAMTOOLS_INDEX(bam_recalibrated)
        bam_recalibrated_index = bam_recalibrated.join(SAMTOOLS_INDEX.out.bai)

        qualimap_bamqc = Channel.empty()
        samtools_stats = Channel.empty()

        if (!skip_bamqc) {
            QUALIMAP_BAMQC(bam_recalibrated, target_bed, params.target_bed)
            qualimap_bamqc = QUALIMAP_BAMQC.out
        }

        if (!skip_samtools) {
            SAMTOOLS_STATS(bam_recalibrated_index)
            samtools_stats = SAMTOOLS_STATS.out.stats
        }

        bam_reports = samtools_stats.mix(qualimap_bamqc)

        //TODO: set bam_recalibrated with all these steps
        // // When using sentieon for mapping, Channel bam_recalibrated is bam_sentieon_recal
        // if (params.sentieon && step == 'mapping') bam_recalibrated = bam_sentieon_recal

        // // When no knownIndels for mapping, Channel bam_recalibrated is bam_duplicates_marked
        // if (!params.known_indels && step == 'mapping') bam_recalibrated = bam_duplicates_marked

        // // When starting with variant calling, Channel bam_recalibrated is input_sample
        // if (step == 'variantcalling') bam_recalibrated = input_sample
        // Creating TSV files to restart from this step
        bam_recalibrated_index.collectFile(storeDir: "${params.outdir}/preprocessing/tsv") { meta, bam, bai ->
            patient = meta.patient
            sample  = meta.sample
            gender  = meta.gender
            status  = meta.status
            bam = "${params.outdir}/preprocessing/${sample}/recalibrated/${sample}.recal.bam"
            bai = "${params.outdir}/preprocessing/${sample}/recalibrated/${sample}.recal.bam.bai"
            ["recalibrated_${sample}.tsv", "${patient}\t${gender}\t${status}\t${sample}\t${bam}\t${bai}\n"]
        }

        bam_recalibrated_index.map { meta, bam, bai ->
            patient = meta.patient
            sample  = meta.sample
            gender  = meta.gender
            status  = meta.status
            bam = "${params.outdir}/preprocessing/${sample}/recalibrated/${sample}.recal.bam"
            bai = "${params.outdir}/preprocessing/${sample}/recalibrated/${sample}.recal.bam.bai"
            "${patient}\t${gender}\t${status}\t${sample}\t${bam}\t${bai}\n"
        }.collectFile(name: 'recalibrated.tsv', sort: true, storeDir: "${params.outdir}/preprocessing/tsv")
    }

    emit:
        bam = bam_recalibrated_index
        qc  = bam_reports
}
