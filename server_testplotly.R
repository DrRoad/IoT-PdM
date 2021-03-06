# library(reshape2)
library(magrittr)
library(saves)
library(shiny)
library(dplyr)
library(curl) # make the jsonlite suggested dependency explicit
library(ggplot2)
library(xts)
library(plotly)
library(forecast)

# Create function for estimating likelihood of greater increase/decrease
make_temp_pdf <- function(offset,sigma){
  pdfvals <- c()
  for (i in 0:101){
    pdfvals <- append(pdfvals, exp(-(i-offset)**2 / (2 * sigma**2)))
  }
  return(pdfvals)
}

# Simulate temperatures for input to test algorithm
boundedMarkovChain <- function(offset,maxStepSize,upperBound,lowerBound,pdfvals,n_sec=86400,full_output=FALSE){
  bmc <- c()
  times <- c()
  bmchist <- integer(1000)
  val <- offset
  set.seed(as.numeric(Sys.time()))
  
  for (i in 0:(n_sec-1)){
    # Add next value as dependent on current state
    val <- val + (runif(1,-0.5,.5)*maxStepSize*(1.01-pdfvals[round(val)+1]))

    # Check bounds
    val <- min(c(max(c(val,lowerBound)),upperBound))
    bmchist[min(c(floor(val*10.0)+1,999))] <- bmchist[min(c(floor(val*10.0)+1,999))]+1
    if (full_output){
      bmc <- append(bmc,val)
      times <- append(times,i)
    } else {
      if (mod(i,max(c(round(n_sec/1000),1)))==0){
        bmc <- append(bmc,val)
        times <- append(times,i)
      }
    }
  }
  return(list("times"=times,"bmc"=bmc,"bmchist"=bmchist))
}

justtheerrors <- function(data,ranges){
  minrange <- round(ranges[1]-(2*ranges[2]),1)
  maxrange <- round(ranges[1]+(2*ranges[2]),1)
  df <- data.frame(cbind(data$times,data$bmc,sign(data$bmc-minrange),sign(data$bmc-maxrange)))
  colnames(df)<- c('Time','Temp','Type','high')

  if (length(which(((df$Type<=0)|(df$high >=0))==TRUE))>0){
    df2 <- df[(df$Type<=0)|(df$high >=0),]
    df2$Type <- "LOW"
    df2$Type[df2$high>0] <- "HIGH"
    return(cbind(round(df2$Time/60,2),round(df2$Temp,2),df2$Type))
  } else {
    df <- data.frame(cbind(NaN,NaN,'N/A'))
    colnames(df) <- c('Time','Temp','Type')
    return(cbind(df$Time,df$Temp,df$Type))
  }
}

shinyServer(function(input, output, session) {

  #---------------------------------------------------
  # Add functionality for plotting data using dygraph
  #---------------------------------------------------
  values <- reactiveValues(run=0,polyorder=1)
  
  # Reactive data for updated time series
  pltdata <- eventReactive(input$gettraining,{
    # Some Info to construct Bounded Markov Chain
    stepSize=2.0 #log10(input$n_sec)
    sigma=stepSize*7.5
    offset = 25
    bmc <- boundedMarkovChain(offset,
                              maxStepSize=5.5,
                              upperBound=100.0,
                              lowerBound=0.0,
                              pdfvals=make_temp_pdf(offset,sigma),
                              n_sec=input$n_sec
                              )
  })
  train_ranges <- reactive({
    tmean<-sum(pltdata()$bmchist*seq(0.05, 99.95, 0.1))/sum(pltdata()$bmchist)
    tstd <-sqrt(sum(pltdata()$bmchist*((seq(0.05, 99.95, 0.1)-tmean)**2))/sum(pltdata()$bmchist))
    c(tmean,tstd)
  })

  output$trainplot <- renderPlot({
    # Create dataframe for time series plots
    mc <- data.frame(cbind(pltdata()$times,pltdata()$bmc))
    colnames(mc) <- c("times","bmc")

    #Calculate basic statistics (mean, std)
    tmean<-train_ranges()[1]
    tstd <-train_ranges()[2]

    # Set up some plotting params
    tlims<-c(max(c( 1.0,min(which(pltdata()$bmchist>0),(tmean-tstd*2)*10)/10.0-0.5)),
             min(c(99.9,max(which(pltdata()$bmchist>0),(tmean+tstd*2)*10)/10.0+0.5)))
    # At most 20 ticks
    tickints <- c(0.25,0.5,1,5,15,30,60,90,120,150,180,240,300,360,720,1440,2880)
    tickint  <- tickints[min(which(tickints-(tail(mc$times,1)/720.0)>=0))]
    if (tickint < 1.0){
      tickunit <- "sec"
      ticklabs <- tickint
    } else if (tickint > 15.0) {
      tickunit <- "hrs"
      ticklabs <- tickint/60.0
    } else {
      tickunit <- "mins"
      ticklabs <- tickint
    }

    # Plot time series data
    ggplot(mc, aes(x=times,y=bmc)) +
      geom_hline(yintercept=tmean+tstd*2,color='blue',linetype="dashed")+
      geom_hline(yintercept=tmean-tstd*2,color='blue',linetype="dashed")+
      geom_line(aes(y=bmc),color='red') +
      scale_x_continuous(name = paste("Time since start (",tickunit,")"), breaks= 0:12*tickint*60,
                         labels=0:12*ticklabs,limits=c(0,mc$times[length(mc$times)])) +
      scale_y_continuous(name = "Temperature (C)",limits = tlims) +
      theme_minimal() + # start with a minimal theme and add what we need
      theme(text = element_text(color = "gray10"),
            axis.text = element_text(face = "italic",size=10),
            axis.title.x = element_text(vjust = -3, size=14), # move title away from axis
            axis.title.y = element_text(vjust = -1, size=14),# move away for axis
            panel.grid.major.y=element_line(colour="black", linetype = "dashed"),
            panel.grid.major.x=element_blank()
      )
  })
  output$trainhist <- renderPlot({
    newhist<-data.frame(cbind(seq(0,99.9,0.1),pltdata()$bmchist))
    colnames(newhist) <- c("temp","bmchist")
    tmean<-sum(pltdata()$bmchist*seq(0.05, 99.95, 0.1))/sum(pltdata()$bmchist)
    tstd <-sqrt(sum(pltdata()$bmchist*((seq(0.05, 99.95, 0.1)-tmean)**2))/sum(pltdata()$bmchist))
    tlims<-c(max(c( 1.0,min(which(pltdata()$bmchist>0),(tmean-tstd*2)*10)/10.0-0.5)),
             min(c(99.9,max(which(pltdata()$bmchist>0),(tmean+tstd*2)*10)/10.0+0.5)))
    ggplot(newhist, aes(y=newhist$bmc,x=newhist$temp)) +
      geom_bar(stat="identity",fill="red",width=0.1)+
      geom_vline(xintercept=tmean-tstd*2,color='blue',linetype="dashed")+
      geom_vline(xintercept=tmean+tstd*2,color='blue',linetype="dashed")+
      annotate("text", label = "Max range", x = tmean+tstd*2, y = max(pltdata()$bmchist),
               size = 5, colour = "blue",vjust=-0.5,hjust=1,fontface=3)+
      annotate("text", label = "Min range", x = tmean-tstd*2, y = max(pltdata()$bmchist),
               size = 5, colour = "blue",vjust=1.25,hjust=1,fontface=3)+
      coord_flip()+
      scale_x_continuous(name = "",limits = tlims)  +
      scale_y_continuous(name = "Observation count")  +
      theme_minimal() +
      theme(text = element_text(color = "gray10"),
            axis.text = element_text(face = "italic",size=10),
            axis.title.x = element_text(vjust = -3, size=14), # move title away from axis
            axis.title.y = element_blank(), # move away for axis
            axis.text.y  = element_blank(), # remove y ticks
            panel.grid.major.y=element_line(colour="black", linetype = "dashed"),
            panel.grid.major.x=element_blank()
      )
  })

  # Update the slider for the normal operating range
  output$minoprange <- renderUI({
    #Calculate basic statistics (mean, std)
    #tmean<-sum(pltdata()$bmchist*seq(0.05, 99.95, 0.1))/sum(pltdata()$bmchist)
    #tstd <-sqrt(sum(pltdata()$bmchist*((seq(0.05, 99.95, 0.1)-tmean)**2))/sum(pltdata()$bmchist))
    numericInput("minrange", "Lower limit (C)",
                value = round(train_ranges()[1]-(train_ranges()[2]*2),1),
                step = 0.1)
  })
  # Update the slider for the normal operating range
  output$maxoprange <- renderUI({
    #Calculate basic statistics (mean, std)
    #tmean<-sum(pltdata()$bmchist*seq(0.05, 99.95, 0.1))/sum(pltdata()$bmchist)
    #tstd <-sqrt(sum(pltdata()$bmchist*((seq(0.05, 99.95, 0.1)-tmean)**2))/sum(pltdata()$bmchist))
    numericInput("maxrange", "Upper limit (C)",
                value = round(train_ranges()[1]+(train_ranges()[2]*2),1),
                step = 0.1)
  })
  
  # Functionality for simulation action buttons
  observeEvent(input$startsim,{
    values$run <- abs(isolate(values$run)-1)
  })
  observeEvent(input$trendsim,{
    values$run <- abs(isolate(values$run)-1)
  })
  observeEvent(input$forecast,{
    values$run <- abs(isolate(values$run)-1)
  })
  
  # Run test -> must simulate sensor data. Run first, plot as if "real time"
  # Generate new data and test if within normal operating range
  rtdata <- eventReactive(values$run,{
    # Some Info to construct Bounded Markov Chain
    stepSize=2.0 #log10(input$n_sec)
    sigma=stepSize*7.5
    offset = 25
    bmc <- boundedMarkovChain(offset,
                              maxStepSize=5.5,
                              upperBound=100.0,
                              lowerBound=0.0,
                              make_temp_pdf(offset,sigma),
                              n_sec=7200, #1 hours
                              full_output=TRUE
    )
  })
  
  # Observe if user changes the order of the polynomial trend fit
  observeEvent(input$trendorder,{
    values$polyorder <- input$trendorder  
  })
  
  # Calculate regression of
  rt_regress <- reactive({
    ts <- ts(rtdata()$bmc,start=0,end=7200)
    model <- lm(rtdata()$bmc ~ poly(rtdata()$times,values$polyorder))
  })
  
  rt_predict <- reactive({
    # Calculate regression 
    dataset <- rtdata()
    time <- dataset$times
    model <- lm(dataset$bmc~ poly(time,values$polyorder))
    dataset$regression <- fitted(model)
    newtime <- data.frame(time=max(time)+seq(1,600,1))
    predictions <- predict(model, newtime, interval="prediction")
    predictions <- data.frame(cbind(newtime,predictions))
  })
  
  # Plot time series chart
  output$timeseries <- renderPlotly({

    p <- plot_ly(rtdata(),x = times/60, y = bmc,
                  mode = "lines",
                  hovermode = "closest",
                  source = "source",
                  name="temperature",
                  line=list(color="rgb(250,0,0)")
                )
    p <- add_trace(p, x=c(rtdata()$times[1]/60,rtdata()$times[length(rtdata()$times)]/60),
                      y=c(round(train_ranges()[1]+(2*train_ranges()[2]),1),
                          round(train_ranges()[1]+(2*train_ranges()[2]),1)),
                      name="Max range",
                      line = list(                        # line is a named list, valid keys: /r/reference/#scatter-line
                              color = "rgb(0, 0, 250,1)",      # line's "color": /r/reference/#scatter-line-color
                              dash = 5,
                              width=1                 # line's "dash" property: /r/reference/#scatter-line-dash
                      )
                  )
    p <- add_trace(p, x=c(rtdata()$times[1]/60,rtdata()$times[length(rtdata()$times)]/60),
                      y=c(round(train_ranges()[1]-(2*train_ranges()[2]),1),
                          round(train_ranges()[1]-(2*train_ranges()[2]),1)),
                      name="Min range",
                      line = list(                        # line is a named list, valid keys: /r/reference/#scatter-line
                              color = "rgb(0, 0, 250,1)",      # line's "color": /r/reference/#scatter-line-color
                              dash = 5,
                              width=1                # line's "dash" property: /r/reference/#scatter-line-dash
                      )
                  ) %>%
    layout(xaxis = list(title = "Time (mins)",
                        gridcolor = "#bfbfbf",
                        domain = c(0, 0.98),
                        range = c(rtdata()$times/60,rtdata()$times[length(rtdata()$times)]/60),
                        tickfont = list(family='Helvetica', face='italic'),
                        showline=FALSE,
                        zeroline=FALSE,
                        showgrid=FALSE
                        ),
            yaxis = list(title = "Temperature (C)",
                         zeroline=FALSE,
                         tickfont = list(family='Helvetica',style='italic'),
                         gridcolor = "#bfbfbf",
                         linetype="dashed"
                         ),
            showlegend=FALSE,
            font = list(family='Helvetica',style='italic')
      )
    p
  })
  
  # Include anomaly table
  output$tabledata = DT::renderDataTable(justtheerrors(rtdata(),train_ranges()),
                                         colnames=c('Time','Temp','Type'),
                                         options=list(pageLength=20),
                                         server = FALSE)
  
  # Plot the time series chart with regression
  output$trendline <- renderPlotly({
    
    trange <- c(rtdata()$times[1]/60,rtdata()$times[length(rtdata()$times)]/60)
    p <- plot_ly(rtdata(),x = times/60, y = bmc,
                 mode = "lines",
                 hovermode = "closest",
                 source = "source",
                 name="temperature",
                 line=list(color="rgb(250,0,0)")
    )
    p <- add_trace(p, x=rtdata()$times/60,
                   y=fitted(rt_regress()),
                   name="Regression",
                   line = list(                        # line is a named list, valid keys: /r/reference/#scatter-line
                     color = "rgb(0, 0, 0,1)"      # line's "color": /r/reference/#scatter-line-color
                   )
    )
    if (input$fcaston==1){
      p <- add_trace(p, x=rt_predict()$time/60,
                        y=rt_predict()$fit,
                        name="Prediction",
                        line = list(                        # line is a named list, valid keys: /r/reference/#scatter-line
                          color = "rgb(0, 0, 0, 1)"      # line's "color": /r/reference/#scatter-line-color
                        )
                     )%>%
            add_trace(x = rt_predict()$time/60, 
                      y = rt_predict()$upr, 
                      type = 'scatter', 
                      mode = 'lines',
                      line = list(color = 'transparent'),
                      showlegend = FALSE, 
                      name = 'Prediction Interval') %>%
            add_trace(x = rt_predict()$time/60, 
                      y = rt_predict()$lwr, 
                      type = 'scatter', 
                      mode = 'lines',
                      fill = 'tonexty', 
                      fillcolor='rgba(0,0,0,0.3)', 
                      line = list(color = 'transparent'),
                      showlegend = FALSE, 
                      name = 'Prediction Interval')
     trange[2] <- max(rt_predict()$time)/60
    }
    p <- add_trace(p, x=trange,
                   y=c(round(train_ranges()[1]+(2*train_ranges()[2]),1),
                       round(train_ranges()[1]+(2*train_ranges()[2]),1)),
                   name="Max range",
                   line = list(                        # line is a named list, valid keys: /r/reference/#scatter-line
                     color = "rgb(0, 0, 250,1)",      # line's "color": /r/reference/#scatter-line-color
                     dash = 5,
                     width=1                 # line's "dash" property: /r/reference/#scatter-line-dash
                   )
    )
    p <- add_trace(p, x=trange,
                   y=c(round(train_ranges()[1]-(2*train_ranges()[2]),1),
                       round(train_ranges()[1]-(2*train_ranges()[2]),1)),
                   name="Min range",
                   line = list(                        # line is a named list, valid keys: /r/reference/#scatter-line
                     color = "rgb(0, 0, 250,1)",      # line's "color": /r/reference/#scatter-line-color
                     dash = 5,
                     width=1                # line's "dash" property: /r/reference/#scatter-line-dash
                   )
    )%>%
    layout(xaxis = list(title = "Time (mins)",
                        gridcolor = "#bfbfbf",
                        domain = c(0, 0.98),
                        range = trange,
                        tickfont = list(family='Helvetica', face='italic'),
                        showline=FALSE,
                        zeroline=FALSE,
                        showgrid=FALSE
                        ),
            yaxis = list(title = "Temperature (C)",
                         zeroline=FALSE,
                         tickfont = list(family='Helvetica',style='italic'),
                         gridcolor = "#bfbfbf",
                         linetype="dashed"
                        ),
            showlegend=FALSE,
            font = list(family='Helvetica',style='italic')
      )
  })
  
  # Plot the time series with regression and prediction
  output$trendforecast <- renderPlotly({
    
    p <- plot_ly(rtdata(),x = times/60, y = bmc,
                 mode = "lines",
                 hovermode = "closest",
                 source = "source",
                 name="temperature",
                 line=list(color="rgb(250,0,0)")
    )
    p <- add_trace(p, x=c(rtdata()$times[1]/60,rtdata()$times[length(rtdata()$times)]/60),
                   y=c(round(train_ranges()[1]+(2*train_ranges()[2]),1),
                       round(train_ranges()[1]+(2*train_ranges()[2]),1)),
                   name="Max range",
                   line = list(                        # line is a named list, valid keys: /r/reference/#scatter-line
                     color = "rgb(0, 0, 250,1)",      # line's "color": /r/reference/#scatter-line-color
                     dash = 5,
                     width=1                 # line's "dash" property: /r/reference/#scatter-line-dash
                   )
    )
    p <- add_trace(p, x=c(rtdata()$times[1]/60,rtdata()$times[length(rtdata()$times)]/60),
                   y=c(round(train_ranges()[1]-(2*train_ranges()[2]),1),
                       round(train_ranges()[1]-(2*train_ranges()[2]),1)),
                   name="Min range",
                   line = list(                        # line is a named list, valid keys: /r/reference/#scatter-line
                     color = "rgb(0, 0, 250,1)",      # line's "color": /r/reference/#scatter-line-color
                     dash = 5,
                     width=1                # line's "dash" property: /r/reference/#scatter-line-dash
                   )
    )
    p <- add_trace(p, x=rtdata()$times/60,
                   y=fitted(rt_regress()),
                   name="Regression",
                   line = list(                        # line is a named list, valid keys: /r/reference/#scatter-line
                     color = "rgb(0, 0, 0,1)"      # line's "color": /r/reference/#scatter-line-color
                   )
    )%>%
      layout(xaxis = list(title = "Time (mins)",
                          gridcolor = "#bfbfbf",
                          domain = c(0, 0.98),
                          range = c(rtdata()$times/60,rtdata()$times[length(rtdata()$times)]/60),
                          tickfont = list(family='Helvetica', face='italic'),
                          showline=FALSE,
                          zeroline=FALSE,
                          showgrid=FALSE
      ),
      yaxis = list(title = "Temperature (C)",
                   zeroline=FALSE,
                   tickfont = list(family='Helvetica',style='italic'),
                   gridcolor = "#bfbfbf",
                   linetype="dashed"
      ),
      showlegend=FALSE,
      font = list(family='Helvetica',style='italic')
      )
    p
  })

  # Coupled hover event
  output$gague <- renderPlotly({

    # Read in hover data
    eventdata <- event_data("plotly_hover", source = "source")
    validate(need(!is.null(eventdata), "Hover over the time series to see operation level"))

    # Get point number
    datapoint <- as.numeric(eventdata$pointNumber)[1]
    rotangle <- ((rtdata()$bmc[datapoint]-train_ranges()[1])/(2*train_ranges()[2]))*(25/3.0)

  })
})
